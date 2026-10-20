import XCTest
@testable import PenumbraLuna

/// Runs every Pele corpus case (Tests/PenumbraTests/MermaidCorpus/, vendored from
/// Pele tests/corpus @ 8603bf3) through Luna's parse and layout. Cases for diagram
/// kinds Luna does not build are skipped; every supported case must lay out, and
/// every flowchart edge must come back with a routed path.
final class LunaMermaidCorpusTests: XCTestCase {
    func testCorpusLaysOut() throws {
        let corpus = try XCTUnwrap(
            Bundle.module.url(forResource: "MermaidCorpus", withExtension: nil),
            "MermaidCorpus resource is missing")
        let files = try FileManager.default.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        var ran = 0
        var skipped = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let cases = try JSONSerialization.jsonObject(with: data) as? [String] ?? []
            for source in cases {
                let prepared = DiagramKindDetector.prepare(source)
                guard DiagramKindDetector.diagramType(for: prepared.kind) != nil,
                      prepared.kind != .zenuml, prepared.kind != .unknown
                else {
                    skipped += 1
                    continue
                }
                do {
                    let positioned = try MermaidRenderer.layout(source)
                    ran += 1
                    // Every flowchart-family edge must be routed end to end.
                    for edge in positioned.flowchartEdges ?? [] {
                        XCTAssertGreaterThanOrEqual(
                            edge.points.count, 2,
                            "\(file.lastPathComponent): edge \(edge.source)->\(edge.target) unrouted")
                    }
                } catch let error as MermaidParserError {
                    switch error {
                    case .unsupportedDiagram:
                        skipped += 1
                    case .limit:
                        // Over-limit corpus inputs must fail cleanly, not hang or crash.
                        ran += 1
                    default:
                        XCTFail("\(file.lastPathComponent): \(error)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(ran, 0, "corpus ran no cases")
    }
}
