import Foundation

/// Shared parse + semantic state for one inspection pass over a Java file.
struct JavaInspectionContext {
    let source: String
    let tree: JavaSyntaxTree
    let file: JavaSourceFileStubs
    let url: URL
    let index: JavaIndex
    let walker: JavaSemanticWalker
    let thresholds: JavaInspectionThresholds
    /// The Java language level of the file's module (8, 11, 17, 21…), or nil when unknown. Rules
    /// that suggest newer syntax stay silent without it.
    let languageLevel: Int?

    /// Whether the file may use a feature introduced in `version`.
    func supports(_ version: Int) -> Bool { (languageLevel ?? 0) >= version }

    init?(
        source: String, tree: JavaSyntaxTree, url: URL, index: JavaIndex,
        thresholds: JavaInspectionThresholds = .standard, languageLevel: Int? = nil
    ) {
        guard !tree.rootNode.hasError else { return nil }
        self.source = source
        self.tree = tree
        self.file = JavaSourceStubBuilder.build(tree: tree, url: url)
        self.url = url
        self.index = index
        self.thresholds = thresholds
        self.languageLevel = languageLevel
        self.walker = JavaSemanticWalker(tree: tree, source: source)
        _ = self.walker.run()
    }
}
