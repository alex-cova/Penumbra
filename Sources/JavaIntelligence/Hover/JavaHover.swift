import EditorIntelligence
import Foundation

/// What a hover shows for the symbol under the caret.
enum JavaResolvedSymbol {
    case type(JavaClassStub)
    case method(JavaMethodStub, declaringClass: String)
    case field(JavaFieldStub, declaringClass: String)
    /// A local variable or parameter: only its declaration line is known.
    case local(name: String, declaration: String)
}

struct JavaHoverContent: Equatable {
    /// Markdown for the popup.
    var markdown: String
    /// The identifier hovered, as UTF-8 bytes of the source.
    var byteRange: Range<Int>
    /// Whether any of the symbols carried Javadoc.
    var hasDocumentation: Bool
}

/// Resolves the Java symbol at a caret to hover Markdown: its signature and, when the source is
/// at hand (the project, a JDK `src.zip`, a `*-sources.jar`), its Javadoc. Never decompiles.
enum JavaHover {
    /// At most this many overloads are listed for one call.
    private static let maxSymbols = 3

    static func resolve(
        source: String,
        fileURL: URL?,
        utf16Offset: Int,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?,
        isAmbient: Bool = false
    ) async -> JavaHoverContent? {
        guard let tree = JavaParseMemo.shared.tree(for: source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        // The name of the class being read sits right under its own Javadoc: an ambient popup there
        // only repeats it (and covers the code), so only an explicit request shows it.
        if isAmbient, JavaReferenceClassifier.isTypeDeclarationName(in: tree, atByteOffset: byteOffset) {
            return nil
        }
        guard let reference = JavaReferenceClassifier.classify(in: tree, atByteOffset: byteOffset) else { return nil }
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        let symbols = Array(await session.resolveSymbols(reference).prefix(maxSymbols))
        guard !symbols.isEmpty else { return nil }
        // Likewise a mention of the class being read (its name, `this`, `new Own(…)`): the reader
        // already knows what it is, so a popup is noise unless they ask for it.
        if isAmbient, refersToOwnType(reference, symbols: symbols, session: session) { return nil }
        var blocks: [String] = []
        var hasDocumentation = false
        for symbol in symbols {
            let documentation = await session.documentation(for: symbol)
            if documentation != nil { hasDocumentation = true }
            blocks.append(await markdown(for: symbol, documentation: documentation, session: session))
        }
        return JavaHoverContent(
            markdown: blocks.joined(separator: "\n\n---\n\n"),
            byteRange: tree.node(atByteOffset: byteOffset).byteRange,
            hasDocumentation: hasDocumentation
        )
    }

    /// Whether every symbol is a type the file declares at its top level, or one the position is
    /// inside, reached by naming it or constructing it.
    private static func refersToOwnType(
        _ reference: JavaReference, symbols: [JavaResolvedSymbol], session: JavaNavigationSession
    ) -> Bool {
        var own = Set(session.context.enclosingTypeQualifiedNames)
        for stub in session.currentClasses where stub.outerQualifiedName == nil { own.insert(stub.qualifiedName) }
        // A class with no declared constructor falls back to the type itself, so both shapes count.
        let isOwn: (JavaResolvedSymbol) -> Bool = {
            switch $0 {
            case .type(let stub): return own.contains(stub.qualifiedName)
            case .method(_, let owner): return own.contains(owner)
            default: return false
            }
        }
        switch reference {
        case .type, .keywordThis, .constructor, .explicitConstructor:
            return symbols.allSatisfy(isOwn)
        default:
            return false
        }
    }

    private static func markdown(for symbol: JavaResolvedSymbol, documentation: String?, session: JavaNavigationSession) async -> String {
        let signature: String
        let owner: String?
        switch symbol {
        case .type(let stub):
            signature = JavaSignatureText.type(stub)
            owner = stub.outerQualifiedName ?? (stub.packageName.isEmpty ? nil : stub.packageName)
        case .method(let method, let declaringClass):
            let ownerStub = await session.index.classStub(qualifiedName: declaringClass)
            signature = JavaSignatureText.method(method, in: ownerStub)
            owner = declaringClass
        case .field(let field, let declaringClass):
            signature = JavaSignatureText.field(field)
            owner = declaringClass
        case .local(_, let declaration):
            signature = declaration
            owner = nil
        }
        var parts = ["```java\n\(signature)\n```"]
        if let owner { parts.append("*\(owner)*") }
        if let documentation {
            let body = JavadocMarkdown.format(documentation)
            if !body.isEmpty { parts.append(body) }
        }
        return parts.joined(separator: "\n\n")
    }
}
