import Foundation

/// Reads `llvm-cov export` JSON (what `swift test --enable-code-coverage` leaves next to the build, found with
/// `swift test --show-codecov-path`) into the report model the Coverage tab and the editor bands already draw.
///
/// The mapping is the one the plan fixed: a SwiftPM target is the report's "package", a source file is its
/// "class" and its source file. Lines come from the export's segments by `llvm-cov show`'s own rule
/// (`LineCoverageStats`), so a line's colour is the count `llvm-cov show` prints beside it. (The export's own `lines`
/// summary can be one higher than the lines `show` prints, so the totals here are counted from the lines.)
///
/// It lives beside the JaCoCo parser because the model does; `SwiftIntelligence` has no dependency on
/// `JavaIntelligence`, and the command that produces the file is `SwiftCoverageCommand`.
public enum LLVMCoverageJSONParser {
    public struct Options: Sendable {
        /// Paths are shown relative to this folder; files outside it (dependencies) are left out.
        public var projectRoot: URL?
        /// Files under a `Tests` folder, or named `*Tests.swift`.
        public var includeTests: Bool
        /// Folders whose files are generated or fetched, never the project's own.
        public var excludedFolders: Set<String>

        public init(
            projectRoot: URL? = nil, includeTests: Bool = false,
            excludedFolders: Set<String> = [".build", "checkouts", "DerivedData", "SourcePackages", "Pods", "Carthage"]
        ) {
            self.projectRoot = projectRoot
            self.includeTests = includeTests
            self.excludedFolders = excludedFolders
        }
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notCoverageData
        case noFiles

        public var errorDescription: String? {
            switch self {
            case .notCoverageData: "The file is not an llvm-cov export."
            case .noFiles: "The coverage data names no source files of this project."
            }
        }
    }

    public static func parse(_ data: Data, name: String, options: Options = Options()) throws -> JavaCoverageReport {
        let export: Export
        do { export = try JSONDecoder().decode(Export.self, from: data) } catch { throw ParseError.notCoverageData }
        guard export.type.hasPrefix("llvm.coverage.json") else { throw ParseError.notCoverageData }
        let root = options.projectRoot?.standardizedFileURL.path

        var byModule: [String: [JavaCoverageSourceFile]] = [:]
        for file in export.data.flatMap(\.files) {
            guard let place = place(of: file.filename, root: root, options: options) else { continue }
            let lines = lines(from: file.segments)
            var totals = JavaCoverageTotals()
            for line in lines {
                totals.lines.covered += line.status == .missed ? 0 : 1
                totals.lines.missed += line.status == .missed ? 1 : 0
            }
            totals.methods = JavaCoverageCounter(
                missed: max(file.summary.functions.count - file.summary.functions.covered, 0), covered: file.summary.functions.covered
            )
            totals.instructions = JavaCoverageCounter(
                missed: max(file.summary.regions.count - file.summary.regions.covered, 0), covered: file.summary.regions.covered
            )
            if let branches = file.summary.branches {
                totals.branches = JavaCoverageCounter(missed: max(branches.count - branches.covered, 0), covered: branches.covered)
            }
            totals.classes = totals.lines.covered > 0 ? JavaCoverageCounter(covered: 1) : JavaCoverageCounter(missed: 1)
            byModule[place.module, default: []].append(JavaCoverageSourceFile(
                name: place.name, packageName: place.module, url: URL(fileURLWithPath: file.filename),
                lines: lines, totals: totals
            ))
        }
        guard !byModule.isEmpty else { throw ParseError.noFiles }

        var packages: [JavaCoveragePackage] = []
        var total = JavaCoverageTotals()
        for module in byModule.keys.sorted() {
            let files = byModule[module]!.sorted { $0.name < $1.name }
            let totals = files.reduce(JavaCoverageTotals()) { $0 + $1.totals }
            let classes = files.map { file in
                JavaCoverageClass(
                    binaryName: module + "/" + (file.name as NSString).deletingPathExtension, sourceFileName: file.name, totals: file.totals
                )
            }
            packages.append(JavaCoveragePackage(name: module, classes: classes, sourceFiles: files, totals: totals))
            total = total + totals
        }
        return JavaCoverageReport(name: name, packages: packages, totals: total)
    }

    // MARK: - Where a file belongs

    /// Shared with `XCCovArchiveParser`: the archive names absolute paths, and the module
    /// placement is the same.
    static func place(of path: String, root: String?, options: Options) -> (module: String, name: String)? {
        let name = (path as NSString).lastPathComponent
        let components: [String]
        if let root {
            guard path.hasPrefix(root + "/") else { return nil }
            components = String(path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
        } else {
            components = path.split(separator: "/").map(String.init)
        }
        guard !components.contains(where: options.excludedFolders.contains) else { return nil }
        let isTest = components.contains("Tests") || components.dropLast().contains { $0.hasSuffix("Tests") } || name.hasSuffix("Tests.swift")
        if isTest, !options.includeTests { return nil }
        // `Sources/<Target>/…` and `Tests/<Target>/…`; anything else is grouped by its first folder.
        if components.count >= 3, components[0] == "Sources" || components[0] == "Tests" { return (components[1], name) }
        if components.count >= 2 { return (components[0], name) }
        return ("(root)", name)
    }

    // MARK: - Lines

    /// `llvm-cov show`'s rule: a line is mapped when the region carried over from the lines above has a count, or a
    /// region with a count starts on it; its count is the larger of the carried count and the counts of the regions
    /// that start on it. A line where one region starts with a count of zero inside a covered one is partial.
    static func lines(from segments: [Segment]) -> [JavaCoverageLine] {
        guard let first = segments.first, let last = segments.last else { return [] }
        var result: [JavaCoverageLine] = []
        var wrapped: Segment?
        var index = 0
        for line in first.line ... max(last.line, first.line) {
            var starting: [Segment] = []
            while index < segments.count, segments[index].line == line {
                starting.append(segments[index])
                index += 1
            }
            func startsRegion(_ segment: Segment) -> Bool { !segment.isGap && segment.hasCount && segment.isRegionEntry }
            let entries = starting.filter(startsRegion)
            let skipped = starting.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
            let mapped = !skipped && ((wrapped?.hasCount ?? false) || !entries.isEmpty)
            if mapped {
                var count = wrapped?.count ?? 0
                for entry in entries { count = max(count, entry.count) }
                let hasUnexecutedRegion = entries.count > 1 && entries.contains { $0.count == 0 }
                let anyExecuted = count > 0
                result.append(JavaCoverageLine(
                    number: line,
                    missedInstructions: (!anyExecuted || hasUnexecutedRegion) ? 1 : 0,
                    coveredInstructions: anyExecuted ? 1 : 0
                ))
            }
            if let lastStart = starting.last { wrapped = lastStart }
        }
        return result
    }

    // MARK: - Format

    struct Segment: Decodable {
        let line: Int
        let column: Int
        let count: Int
        let hasCount: Bool
        let isRegionEntry: Bool
        let isGap: Bool

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            line = try container.decode(Int.self)
            column = try container.decode(Int.self)
            count = try container.decode(Int.self)
            hasCount = try container.decode(Bool.self)
            isRegionEntry = (try? container.decode(Bool.self)) ?? false
            isGap = (try? container.decode(Bool.self)) ?? false
        }
    }

    private struct Counter: Decodable {
        let count: Int
        let covered: Int
    }

    private struct Summary: Decodable {
        let functions: Counter
        let regions: Counter
        let lines: Counter
        let branches: Counter?
    }

    private struct FileEntry: Decodable {
        let filename: String
        let segments: [Segment]
        let summary: Summary
    }

    private struct Data_: Decodable {
        let files: [FileEntry]
    }

    private struct Export: Decodable {
        let type: String
        let data: [Data_]
    }
}
