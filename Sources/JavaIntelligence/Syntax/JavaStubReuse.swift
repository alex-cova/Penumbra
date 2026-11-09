import Foundation
import LanguageSyntax

/// Reparses a Java file after an edit and produces its stubs, reusing the previous stubs when the
/// edit cannot have changed them.
///
/// ``JavaSourceStubBuilder`` reads only declarations: package, imports, and for each member of a
/// type body its signature, modifiers, javadoc and names. It never looks inside a method or
/// constructor body, and local and anonymous classes are not stubs. So an edit strictly inside
/// one method or constructor body leaves every stub's content as it was; what moves is the byte
/// range some stubs carry (`JavaStubOrigin.source`), which lies after the edit or around it.
///
/// Reuse is allowed only when all of this holds, and any other edit rebuilds in full:
/// - the edit (one contiguous byte range, from a diff of the two texts) lies strictly between the
///   braces of a method or constructor body, in the old tree and in the new tree;
/// - the body starts where it did and ends exactly `delta` later, and so does every ancestor up to
///   the root: nothing around the body was re-shaped;
/// - the body is properly closed (a `}` that is not a MISSING node), in both trees;
/// - every stub range endpoint lies outside the replaced bytes, so it can be moved by `delta`.
///
/// The full rebuild stays the reference: `JavaStubReuseTests` compares the two on generated edits.
enum JavaStubReuse {
    struct Result {
        let tree: JavaSyntaxTree
        let stubs: JavaSourceFileStubs
        /// Whether `stubs` came from the previous stubs instead of a rebuild.
        let reusedStubs: Bool
    }

    /// `text` parsed incrementally from `previous.tree`, with its stubs. `nil` when the
    /// incremental parse fails; the caller then parses from scratch.
    static func reparse(
        previous: (tree: JavaSyntaxTree, stubs: JavaSourceFileStubs),
        to text: String,
        parser: JavaSyntaxParser,
        url: URL
    ) -> Result? {
        let parsed: (tree: JavaSyntaxTree, edit: JavaParseEdit)? = JavaCompletionStageTimer.measure("parse") {
            let newBytes = Array(text.utf8)
            guard let edit = JavaParseEdit.diff(from: previous.tree.sourceBytes, to: newBytes) else { return nil }
            // A copy: an earlier request suspended mid-lookup may still be reading the original.
            let edited = previous.tree.copy()
            edited.apply(edit)
            // The one array of the new text's bytes: the diff reads it and the new tree keeps it.
            guard let tree = parser.parseIncremental(oldTree: edited, bytes: newBytes) else { return nil }
            return (tree, edit)
        }
        guard let parsed else {
            // Same bytes: nothing moved.
            return JavaParseEdit.diff(from: previous.tree.sourceBytes, to: Array(text.utf8)) == nil
                ? Result(tree: previous.tree, stubs: previous.stubs, reusedStubs: true) : nil
        }
        return JavaCompletionStageTimer.measure("stubs") {
            if let reused = reuse(previous: previous, newTree: parsed.tree, edit: parsed.edit) {
                JavaStubReuseStatistics.note(reused: true)
                return Result(tree: parsed.tree, stubs: reused, reusedStubs: true)
            }
            JavaStubReuseStatistics.note(reused: false)
            return Result(tree: parsed.tree, stubs: JavaSourceStubBuilder.build(tree: parsed.tree, url: url), reusedStubs: false)
        }
    }

    /// `UMBRA_JAVA_STUB_REUSE=0` rebuilds the stubs on every edit, as before reuse existed: a
    /// fallback if reuse is ever suspected, and how the release harness measures the difference.
    private static let isEnabled = ProcessInfo.processInfo.environment["UMBRA_JAVA_STUB_REUSE"] != "0"

    /// The previous stubs moved past the edit, or `nil` when they cannot be shown to still hold.
    static func reuse(
        previous: (tree: JavaSyntaxTree, stubs: JavaSourceFileStubs), newTree: JavaSyntaxTree, edit: JavaParseEdit
    ) -> JavaSourceFileStubs? {
        guard isEnabled else { return nil }
        let start = edit.startByte
        let oldEnd = edit.oldEndByte
        let newEnd = edit.newEndByte
        let delta = newEnd - oldEnd

        guard let oldBody = enclosingBody(in: previous.tree, range: start..<oldEnd),
              let newBody = enclosingBody(in: newTree, range: start..<newEnd),
              oldBody.startByte < start, oldEnd < oldBody.endByte,
              newBody.startByte < start, newEnd < newBody.endByte,
              isClosed(oldBody), isClosed(newBody) else { return nil }

        // The body and everything above it kept its start and moved its end by exactly `delta`.
        var old: SyntaxNode? = oldBody
        var new: SyntaxNode? = newBody
        while let a = old, let b = new {
            guard a.type == b.type, a.startByte == b.startByte, b.endByte == a.endByte + delta else { return nil }
            old = a.parent
            new = b.parent
        }
        guard old == nil, new == nil else { return nil }
        // Everything around the body parses without errors, in both trees. Tree-sitter recovers
        // from a syntax error globally: with an error elsewhere in the file, an edit in this body
        // can make it read a declaration far away differently (an enum constant list missing its
        // `;`, found by `testErrorRecoveryElsewhereInTheFileIsNotReused`) while this body and its
        // ancestors keep their extents. Clean text parses the same wherever it sits, so with no
        // errors outside the body the declarations are the ones the old stubs describe. Errors
        // inside the body are fine and common: that is what typing looks like.
        guard siblingsAreClean(around: oldBody), siblingsAreClean(around: newBody) else { return nil }

        func moved(_ offset: Int) -> Int? {
            if offset <= start { return offset }
            if offset >= oldEnd { return offset + delta }
            return nil  // inside the replaced bytes: no way to say where it went
        }
        var classes: [JavaClassStub] = []
        classes.reserveCapacity(previous.stubs.classes.count)
        for stub in previous.stubs.classes {
            guard case .source(let url, let range) = stub.origin else {
                classes.append(stub)
                continue
            }
            guard let lower = moved(range.lowerBound), let upper = moved(range.upperBound) else { return nil }
            if lower == range.lowerBound, upper == range.upperBound {
                classes.append(stub)
            } else {
                classes.append(stub.withOrigin(.source(url, nameRange: lower..<upper)))
            }
        }
        return JavaSourceFileStubs(packageName: previous.stubs.packageName, imports: previous.stubs.imports, classes: classes)
    }

    /// The innermost method or constructor body block around `range`, if the range is inside one.
    private static func enclosingBody(in tree: JavaSyntaxTree, range: Range<Int>) -> SyntaxNode? {
        var node: SyntaxNode? = tree.node(inByteRange: range)
        while let current = node {
            if current.type == "block", let owner = current.parent,
               owner.type == "method_declaration" || owner.type == "constructor_declaration",
               let body = owner.child(byFieldName: "body"),
               body.startByte == current.startByte, body.endByte == current.endByte {
                return current
            }
            node = current.parent
        }
        return nil
    }

    /// Whether, at every level from `node` up to the root, every child of the parent other than the
    /// one on the path is free of syntax errors and MISSING tokens.
    private static func siblingsAreClean(around node: SyntaxNode) -> Bool {
        // A tree with no error anywhere (the usual case, and what the dummy identifier is for) has
        // clean siblings; this skips walking every member of a large class.
        if !node.tree.rootNode.hasError { return true }
        var path: SyntaxNode = node
        while let parent = path.parent {
            var clean = true
            let pathStart = path.startByte
            let pathEnd = path.endByte
            parent.enumerateChildren { child, _ in
                guard clean else { return }
                if child.startByte == pathStart, child.endByte == pathEnd, child.type == path.type { return }
                if child.hasError || child.isMissing || child.isError { clean = false }
            }
            guard clean else { return false }
            path = parent
        }
        return true
    }

    /// A block whose last child is a real `}`: tree-sitter closes an unterminated block with a
    /// zero-width MISSING token, which says nothing about where the body really ends.
    private static func isClosed(_ block: SyntaxNode) -> Bool {
        guard block.childCount >= 2, !block.isMissing, !block.isError,
              let last = block.child(at: block.childCount - 1) else { return false }
        return last.type == "}" && !last.isMissing && last.endByte == block.endByte && last.byteRange.count == 1
    }
}

/// How often stubs were reused and how often rebuilt, for tests and the release harness.
@_spi(Benchmarks)
public enum JavaStubReuseStatistics {
    public struct Counts: Sendable, Equatable {
        public var reused = 0
        public var rebuilt = 0
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var counts = Counts()
    }

    private static let state = State()

    public static var counts: Counts {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.counts
    }

    public static func reset() {
        state.lock.lock()
        state.counts = Counts()
        state.lock.unlock()
    }

    static func note(reused: Bool) {
        state.lock.lock()
        if reused { state.counts.reused += 1 } else { state.counts.rebuilt += 1 }
        state.lock.unlock()
    }
}
