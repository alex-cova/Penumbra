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
        self.init(
            toleratingErrors: source, tree: tree, url: url, index: index,
            thresholds: thresholds, languageLevel: languageLevel)
    }

    /// Error-tolerant construction for diagnostics on half-typed files. The stub builder,
    /// the walker and the symbol tables all walk by expected node type, so they skip ERROR
    /// subtrees by construction and stay trustworthy for well-formed regions; what they
    /// cannot see is recorded in `errorRanges`, so the pipeline can suppress findings that
    /// touch broken regions. Rules that need complete tables (unused-style, unresolved,
    /// typed) stay gated by the caller: silence from a skipped subtree reads as absence.
    let hasError: Bool
    /// Byte ranges of the outermost `ERROR` and `MISSING` nodes: positions no finding may
    /// cover, because the text there is not what the user wrote yet.
    let errorRanges: [Range<Int>]

    init(
        toleratingErrors source: String, tree: JavaSyntaxTree, url: URL, index: JavaIndex,
        thresholds: JavaInspectionThresholds = .standard, languageLevel: Int? = nil
    ) {
        self.source = source
        self.tree = tree
        self.file = JavaSourceStubBuilder.build(tree: tree, url: url)
        self.url = url
        self.index = index
        self.thresholds = thresholds
        self.languageLevel = languageLevel
        self.walker = JavaSemanticWalker(tree: tree, source: source)
        _ = self.walker.run()
        self.hasError = tree.rootNode.hasError
        self.errorRanges = Self.errorRanges(in: tree)
    }

    /// Whether `inspection`'s range touches a broken region. Findings there describe text
    /// the user has not finished writing, so they are dropped, never drawn. A finding that
    /// merely ends where breakage starts still covers intact text and is kept.
    func touchesError(_ inspection: JavaInspection) -> Bool {
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: inspection.range.start.utf16Offset, in: source)
        let end = JavaNavigationText.utf8ByteOffset(forUTF16Offset: inspection.range.end.utf16Offset, in: source)
        if start == end {
            return errorRanges.contains { $0.lowerBound <= start && start < $0.upperBound }
        }
        return errorRanges.contains { $0.overlaps(start..<end) }
    }

    private static func errorRanges(in tree: JavaSyntaxTree) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            // Outermost only: the range covers everything broken underneath it.
            if node.type == "ERROR" || node.isMissing {
                ranges.append(node.byteRange)
                continue
            }
            for index in (0..<node.childCount).reversed() {
                if let child = node.child(at: index) { stack.append(child) }
            }
        }
        return ranges
    }
}
