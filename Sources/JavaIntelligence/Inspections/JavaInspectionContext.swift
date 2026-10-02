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

    init?(source: String, tree: JavaSyntaxTree, url: URL, index: JavaIndex, thresholds: JavaInspectionThresholds = .standard) {
        guard !tree.rootNode.hasError else { return nil }
        self.source = source
        self.tree = tree
        self.file = JavaSourceStubBuilder.build(tree: tree, url: url)
        self.url = url
        self.index = index
        self.thresholds = thresholds
        self.walker = JavaSemanticWalker(tree: tree, source: source)
        _ = self.walker.run()
    }
}
