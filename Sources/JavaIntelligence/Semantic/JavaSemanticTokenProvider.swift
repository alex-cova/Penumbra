import Foundation

/// Classifies the identifiers of a Java file: types (by kind), methods (declaration or call),
/// constructors, fields, enum constants, parameters, locals and type parameters.
///
/// It is one pass over the tree-sitter tree with a scope chain, so a local or parameter shadows a
/// field of the same name, and the cost grows with the file, not the classpath. Types the file does
/// not declare are looked up in the optional ``JavaIndex`` (through its imports, package and
/// `java.lang`, once per distinct name) to tell an interface from a class; without an index they
/// are classes. Members inherited from a superclass are not resolved, so such a bare name gets no
/// token rather than a wrong one. A file with syntax errors is classified around them.
public actor JavaSemanticTokenProvider {
    private let index: JavaIndex?
    private static let maxIndexLookups = 200

    public init(index: JavaIndex? = nil) {
        self.index = index
    }

    /// The tokens of `source` ordered by position, or `nil` when the task was cancelled.
    public func tokens(for source: String) async -> [JavaSemanticToken]? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let walker = JavaSemanticWalker(tree: tree, source: source)
        guard walker.run() else { return nil }
        var kinds: [String: JavaTypeKind] = [:]
        if let index {
            for name in walker.undeclaredTypeNames.sorted().prefix(Self.maxIndexLookups) {
                if Task.isCancelled { return nil }
                for candidate in walker.candidateQualifiedNames(for: name) {
                    if let stub = await index.classStub(qualifiedName: candidate) {
                        kinds[name] = stub.kind
                        break
                    }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        return walker.finish(externalKinds: kinds)
    }
}
