import EditorIntelligence
import Foundation

/// Benchmarks only (`@_spi(Benchmarks) import Penumbra`): where the time of one workspace-index
/// parse (`TreeSitterLanguageParser.parse`) goes, and what an incremental reparse would save (F19).
@_spi(Benchmarks)
public enum IndexingParseBenchmark {
    public struct Breakdown: Sendable {
        public var fullParse = 0.0
        public var incrementalParse = 0.0
        public var symbols = 0.0
        public var words = 0.0
        public var imports = 0.0
        public var parserCreation = 0.0
        public var symbolCount = 0
        public var wordCount = 0
    }

    public static func measure(language: TreeSitterLanguage, text: String) -> Breakdown {
        var result = Breakdown()
        let documentID = DocumentID()
        func clock<T>(_ body: () -> T) -> (T, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = body()
            return (value, Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000)
        }
        let (parser, creation) = clock { () -> TreeSitterParser in
            let mode = TreeSitterLanguageMode(language: language)
            let parser = TreeSitterParser(encoding: .treeSitterUTF16)
            parser.language = mode.language.languagePointer
            return parser
        }
        result.parserCreation = creation
        let (tree, full) = clock { parser.parse(text as NSString) }
        result.fullParse = full
        let (symbols, symbolSeconds) = clock {
            TreeSitterSyntaxTree.extractSymbols(tree: tree, documentID: documentID, text: text, languageConfiguration: nil)
        }
        result.symbols = symbolSeconds
        result.symbolCount = symbols.count
        let (words, wordSeconds) = clock { TreeSitterSyntaxTree.extractWords(from: text) }
        result.words = wordSeconds
        result.wordCount = words.count
        let (_, importSeconds) = clock { TreeSitterSyntaxTree.extractImports(tree: tree, text: text) }
        result.imports = importSeconds

        // One character typed in the middle, reparsed against the edited old tree.
        if let tree {
            let nsText = text as NSString
            let location = nsText.length / 2
            var row = 0
            var lineStart = 0
            nsText.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                row += 1
                lineStart = enclosing.location + enclosing.length
            }
            let column = max(location - lineStart, 0)
            let edited = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "x") as NSString
            let point = TreeSitterTextPoint(row: UInt32(row), column: UInt32(column * 2))
            let newPoint = TreeSitterTextPoint(row: UInt32(row), column: UInt32((column + 1) * 2))
            tree.apply(TreeSitterInputEdit(
                startByte: ByteCount(location * 2),
                oldEndByte: ByteCount(location * 2),
                newEndByte: ByteCount((location + 1) * 2),
                startPoint: point,
                oldEndPoint: point,
                newEndPoint: newPoint
            ))
            let (_, incremental) = clock { parser.parse(edited, oldTree: tree) }
            result.incrementalParse = incremental
        }
        return result
    }

    /// One whole index pass (`TreeSitterLanguageParser.parse`: parse plus symbols, words, imports)
    /// of a document after one typed character in its middle, from scratch and against the
    /// document's previous tree.
    public static func measureIndexPass(makeLanguage: @Sendable () -> TreeSitterLanguage, text: String) async -> (fromScratch: Double, incremental: Double) {
        func document(_ text: String, id: DocumentID, version: Int) -> Document {
            let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                id: id,
                url: URL(fileURLWithPath: "/tmp/\(id).txt"),
                displayName: "b",
                contentSnapshot: TextSnapshot(version: version, text: text),
                selection: Selection(range: TextRange(start: position, end: position)),
                cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 1, height: 1),
                languageIdentifier: nil
            )
        }
        let id = DocumentID()
        let nsText = text as NSString
        let edited = nsText.replacingCharacters(in: NSRange(location: nsText.length / 2, length: 0), with: "x")
        let warm = TreeSitterLanguageParser(language: makeLanguage())
        _ = await warm.parse(document: document(text, id: id, version: 1))
        var start = DispatchTime.now().uptimeNanoseconds
        _ = await warm.parse(document: document(edited, id: id, version: 2))
        let incremental = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        let cold = TreeSitterLanguageParser(language: makeLanguage())
        start = DispatchTime.now().uptimeNanoseconds
        _ = await cold.parse(document: document(edited, id: id, version: 2))
        let fromScratch = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        return (fromScratch, incremental)
    }
}
