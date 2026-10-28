import Foundation
import SwiftSyntax

/// Delete the declaration at the caret: a function, variable, type or enum case that nothing uses.
///
/// The removal range is built on swift-syntax, not by reusing a line from another refactoring:
/// the declaration node (attributes included), its doc comment (`///` or `/** */` trivia directly
/// above, contiguous), the line when nothing else is on it, and one surrounding blank line, so no
/// double gap remains. A `// MARK:`, `// umbra:disable` or plain `//` comment above stays where it
/// is and stops the range; anything else on the declaration's line refuses the deletion.
///
/// What it refuses, with a reason: a binding in `var a, b`, an enum case in a multi-case list, an
/// `override`, and a protocol requirement. Whether anything uses the name is not known here: the
/// provider asks the rename provider (the declaration family across files) before deleting.
public enum SwiftSafeDelete {
    /// A name the caret can delete. Availability only: whether deleting is safe is decided by the
    /// usages check and by ``edits(in:caret:)``.
    struct Target {
        enum Kind {
            case function
            case variable
            case type
            case enumCase
        }

        /// Whether the name stands alone in its declaration: one binding, one case element.
        /// Functions and types always do.
        let name: String
        let nameBytes: Range<Int>
        let node: Syntax
        let kind: Kind
        let modifiers: DeclModifierListSyntax?
        let standsAlone: Bool
    }

    /// The deletable name at `caret` (a UTF-8 byte offset), or nil when the caret is not on one.
    static func target(in text: String, caret: Int) -> Target? {
        guard let file = SwiftRefactoringFile.load(text) else { return nil }
        return target(in: file, caret: caret)
    }

    static func target(in file: SwiftRefactoringFile, caret: Int) -> Target? {
        guard caret <= file.utf8.count else { return nil }
        let position = AbsolutePosition(utf8Offset: caret)
        var token = file.tree.token(at: position)
        // The caret sits between tokens after a name as well as on it.
        if token == nil, caret > 0 { token = file.tree.token(at: AbsolutePosition(utf8Offset: caret - 1)) }
        guard let token else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let decl = current.as(FunctionDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .function, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(VariableDeclSyntax.self) {
                for binding in decl.bindings {
                    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    if let target = named(
                        name: pattern.identifier, node: current, kind: .variable,
                        modifiers: decl.modifiers, caret: caret
                    ) {
                        return target
                    }
                }
                return nil
            }
            if let decl = current.as(StructDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(ClassDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(EnumDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(ActorDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(ProtocolDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(TypeAliasDeclSyntax.self) {
                return named(name: decl.name, node: current, kind: .type, modifiers: decl.modifiers, caret: caret)
            }
            if let decl = current.as(EnumCaseDeclSyntax.self) {
                for element in decl.elements {
                    if let target = named(
                        name: element.name, node: current, kind: .enumCase, modifiers: nil, caret: caret
                    ) {
                        return target
                    }
                }
                return nil
            }
            node = current.parent
        }
        return nil
    }

    /// The name check every declaration goes through: the caret is on the name (or just past it).
    /// The first supported declaration above the caret wins; anything else on the way up (a use of
    /// the name, a parameter, a statement) means the caret is not on a declaration.
    private static func named(
        name: TokenSyntax, node: Syntax, kind: Target.Kind, modifiers: DeclModifierListSyntax?, caret: Int
    ) -> Target? {
        let bytes = SwiftRefactoringFile.trimmed(name)
        guard bytes.lowerBound <= caret, caret <= bytes.upperBound else { return nil }
        let standsAlone: Bool
        switch kind {
        case .variable:
            standsAlone = node.as(VariableDeclSyntax.self)?.bindings.count == 1
        case .enumCase:
            standsAlone = node.as(EnumCaseDeclSyntax.self)?.elements.count == 1
        case .function, .type:
            standsAlone = true
        }
        return Target(
            name: name.text, nameBytes: bytes, node: node, kind: kind, modifiers: modifiers, standsAlone: standsAlone
        )
    }

    /// Deletes the declaration whose name holds `caret`, or says why it cannot be done safely.
    public static func edits(in text: String, caret: Int) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard let target = target(in: file, caret: caret) else {
            return .failure(.init("Place the caret on the name of a function, variable, type or enum case to delete."))
        }
        switch target.kind {
        case .variable where !target.standsAlone:
            return .failure(.init("'\(target.name)' is declared with other names."))
        case .enumCase where !target.standsAlone:
            return .failure(.init("'\(target.name)' shares its case with other cases."))
        default:
            break
        }
        if let modifiers = target.modifiers,
           modifiers.contains(where: { $0.name.tokenKind == .keyword(.override) }) {
            return .failure(.init("'\(target.name)' overrides another declaration."))
        }
        var ancestor: Syntax? = target.node.parent
        while let current = ancestor {
            if current.is(ProtocolDeclSyntax.self) {
                return .failure(.init("'\(target.name)' is a protocol requirement."))
            }
            ancestor = current.parent
        }
        guard let range = removalRange(of: target.node, in: file) else {
            return .failure(.init("'\(target.name)' shares its line with other code."))
        }
        return .success([SwiftTextEdit(bytes: range, replacement: "")])
    }

    /// The bytes to delete: the node and its contiguous doc comment, whole lines, and one
    /// surrounding blank line (the following one, else the preceding one). Nil when other code
    /// shares the node's first or last line.
    static func removalRange(of node: Syntax, in file: SwiftRefactoringFile) -> Range<Int>? {
        let utf8 = file.utf8
        var start = SwiftRefactoringFile.trimmed(node).lowerBound
        let end = SwiftRefactoringFile.trimmed(node).upperBound
        // Up over contiguous doc comments. Anything else — a MARK, a suppression, a plain comment,
        // a blank line — stays and stops the range.
        var newlines = 0
        var scanning = true
        var offset = start
        for piece in node.leadingTrivia.reversed() where scanning {
            let length = piece.sourceLength.utf8Length
            switch piece {
            case .spaces, .tabs, .verticalTabs, .formfeeds:
                break
            case .newlines(let n), .carriageReturns(let n), .carriageReturnLineFeeds(let n):
                newlines += n
                if newlines > 1 { scanning = false }
            case .docLineComment, .docBlockComment:
                if newlines > 1 {
                    scanning = false
                } else {
                    start = offset - length
                    newlines = 0
                }
            default:
                scanning = false
            }
            offset -= length
        }
        // The line, when nothing else is on it.
        var lineStart = start
        while lineStart > 0, utf8[lineStart - 1] != 10, utf8[lineStart - 1] != 13 { lineStart -= 1 }
        guard utf8[lineStart ..< start].allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
        start = lineStart
        var lineEnd = end
        while lineEnd < utf8.count, utf8[lineEnd] != 10, utf8[lineEnd] != 13 { lineEnd += 1 }
        let rest = String(decoding: utf8[end ..< lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("//") || blockCommentOnly(rest) else { return nil }
        var stop = lineEnd
        if stop < utf8.count {
            stop = pastBreak(stop, in: utf8)
        } else if start > 0 {
            start -= 1
        }
        // One surrounding blank line, so no double gap remains: the following one, else the
        // preceding one.
        if let blank = blankLine(at: stop, in: utf8) {
            stop = blank
        } else if start > 0, let above = blankLineEnding(at: start - 1, in: utf8) {
            start = above
        }
        return start ..< stop
    }

    /// A `/* … */` comment that opens and closes on this line: anything else is code the fix must
    /// not delete.
    private static func blockCommentOnly(_ rest: String) -> Bool {
        guard rest.hasPrefix("/*"), let end = rest.range(of: "*/") else { return false }
        return rest[end.upperBound...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Past one line break at `offset` (`\n`, `\r\n` or `\r`).
    private static func pastBreak(_ offset: Int, in utf8: [UInt8]) -> Int {
        if utf8[offset] == 13, offset + 1 < utf8.count, utf8[offset + 1] == 10 { return offset + 2 }
        return offset + 1
    }

    /// Past the blank line at `offset`, or nil when that line holds anything but whitespace.
    private static func blankLine(at offset: Int, in utf8: [UInt8]) -> Int? {
        var end = offset
        while end < utf8.count, utf8[end] == 32 || utf8[end] == 9 { end += 1 }
        guard end < utf8.count else { return nil }
        guard utf8[end] == 10 || utf8[end] == 13 else { return nil }
        return pastBreak(end, in: utf8)
    }

    /// The start of the blank line ending just before `offset` (a line break), or nil.
    private static func blankLineEnding(at offset: Int, in utf8: [UInt8]) -> Int? {
        // `offset` is the break ending the previous line; the line before it is blank when only
        // whitespace lies between its own start and `offset`.
        var lineStart = offset
        while lineStart > 0, utf8[lineStart - 1] != 10, utf8[lineStart - 1] != 13 { lineStart -= 1 }
        guard utf8[lineStart ..< offset].allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
        return lineStart
    }
}
