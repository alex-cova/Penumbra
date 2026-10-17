import EditorIntelligence
import Foundation

/// Copy Reference for Java: `pkg.Class#method(int, String)`, `pkg.Class.FIELD`, or the
/// qualified name of a type. Resolved from the file's own declarations first, then the index.
public actor JavaSymbolReferenceProvider: SymbolReferenceProviding {
    private let index: JavaIndex

    public init(index: JavaIndex) {
        self.index = index
    }

    public func symbolReference(for document: Document, at position: TextPosition) async -> String? {
        guard document.languageIdentifier == "java" else { return nil }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty else { return nil }
        let ns = source as NSString
        let offset = min(max(0, position.utf16Offset), ns.length)
        var start = offset
        var end = offset
        func isIdentifier(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return isCompletionIdentifierScalar(scalar)
        }
        while start > 0, isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isIdentifier(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        let name = ns.substring(with: NSRange(location: start, length: end - start))

        // Declarations in this file win: they cover the caret-on-declaration case, which is
        // the common one in a read-only attached source.
        if let tree = JavaSyntaxParser().parse(source) {
            let stubs = JavaSourceStubBuilder.build(
                tree: tree, url: document.url ?? URL(fileURLWithPath: "/unsaved.java")
            )
            for stub in stubs.classes {
                if stub.simpleName == name { return stub.qualifiedName }
                for method in stub.methods where method.name == name {
                    let parameters = method.parameters.map(\.type.simpleDisplayName).joined(separator: ", ")
                    return "\(stub.qualifiedName)#\(name)(\(parameters))"
                }
                for field in stub.fields where field.name == name {
                    return "\(stub.qualifiedName).\(name)"
                }
            }
        }
        // A type used in this file but declared elsewhere.
        let matches = await index.classes(simpleName: name, limit: 2)
        if matches.count == 1 { return matches[0].qualifiedName }
        return nil
    }
}
