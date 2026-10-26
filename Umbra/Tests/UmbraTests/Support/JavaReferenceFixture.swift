import XCTest
@testable import JavaIntelligence

/// Multi-file Java fixtures for the reference tests: files written under a scratch directory,
/// stubs indexed, and an optional `€` caret marker in one of them.
final class JavaReferenceFixture {
    let root: URL
    private(set) var sources: [String: String] = [:]
    private var caret: (file: String, utf16Offset: Int)?
    private(set) var environment: JavaReferenceEnvironment?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("java-refs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func add(_ name: String, _ marked: String) throws -> URL {
        var source = marked
        if let marker = marked.range(of: "€") {
            source = marked.replacingOccurrences(of: "€", with: "")
            let offset = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
            caret = (name, offset)
        }
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        sources[name] = source
        return url
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// The file and UTF-16 offset of the `€` marker.
    var caretLocation: (file: String, utf16Offset: Int)? { caret }

    /// Indexes every added file and returns the environment.
    @discardableResult
    func build(gradleModel: JavaGradleProjectModel? = nil, indexPaths: JavaIndexPaths? = nil) async throws -> JavaReferenceEnvironment {
        var stubs: [JavaClassStub] = []
        for (name, source) in sources {
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: url(name)).classes)
        }
        let shard = root.appendingPathComponent("shard-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let environment = JavaReferenceEnvironment(
            index: index, cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            gradleModel: gradleModel, indexPaths: indexPaths
        )
        self.environment = environment
        return environment
    }

    /// The symbol at the `€` marker.
    func symbolID() async throws -> JavaSymbolID? {
        let environment = try await environmentOrBuild()
        let caret = try XCTUnwrap(caret, "no € marker")
        return await JavaSymbolIdentity.symbolID(
            at: caret.utf16Offset, in: try XCTUnwrap(sources[caret.file]), url: url(caret.file), environment: environment
        )
    }

    func requireID(file: StaticString = #filePath, line: UInt = #line) async throws -> JavaSymbolID {
        guard let id = try await symbolID() else {
            XCTFail("no symbol at the caret", file: file, line: line)
            throw CancellationError()
        }
        return id
    }

    /// Usages found by the file resolver in a single file.
    func fileUsages(of id: JavaSymbolID, in name: String) async throws -> [JavaUsage] {
        let environment = try await environmentOrBuild()
        return await JavaFileUsageResolver.usages(of: id, source: try XCTUnwrap(sources[name]), url: url(name), environment: environment)
    }

    /// Project-wide usages through the text-scan candidate source.
    func search(_ id: JavaSymbolID, includeDeclarations: Bool = true) async throws -> [JavaUsage] {
        let environment = try await environmentOrBuild()
        return await JavaUsageSearch.collect(
            id, candidates: JavaTextScanCandidateSource(), roots: [root], environment: environment,
            includeDeclarations: includeDeclarations
        )
    }

    private func environmentOrBuild() async throws -> JavaReferenceEnvironment {
        if let environment { return environment }
        return try await build()
    }

    /// `File.java: trimmed line` for each usage, in file then position order.
    func lines(_ usages: [JavaUsage]) -> [String] {
        usages.map { "\($0.url.lastPathComponent): \($0.lineText.trimmingCharacters(in: .whitespaces))" }
    }

    func text(of usage: JavaUsage) -> String {
        guard let source = sources[usage.url.lastPathComponent] else { return "" }
        return (source as NSString).substring(with: usage.utf16Range)
    }
}
