import Foundation

/// Reads `xcrun xccov view` JSON (what `xcodebuild test -enableCodeCoverage YES` leaves in the
/// result bundle) into the report model the Coverage tab and the editor bands already draw.
///
/// The mapping is the plan's:
/// - The archive (`xccov view --archive --json`) is `{ path: [line] }`: a line is covered when its
///   count ran, missed when it did not, and partial when a subrange never ran (as in `llvm-cov`).
///   Files the run never touched are absent, so they get no bands rather than missed ones.
/// - Placement reuses `LLVMCoverageJSONParser.Options` (project root, tests, excluded folders) and
///   its module placement: a target is the report's package, a file its class and its source file.
///   Both sides resolve symlinks first: the archive records the build's absolute paths, which can
///   differ textually from the workspace root through a symlinked parent (`/var` on macOS).
/// - Per-file totals come from `--report --json` (functions for methods, the file's line counters
///   for instructions); the lines counter is counted from the lines, as in `llvm-cov`, and the
///   classes counter marks a file covered when any of its lines ran.
///
/// It lives beside the JaCoCo and llvm-cov parsers because the model does; `SwiftIntelligence`
/// has no dependency on `JavaIntelligence`.
public enum XCCovArchiveParser {
    public enum ParseError: Error, LocalizedError, Equatable {
        case notCoverageData
        case noFiles

        public var errorDescription: String? {
            switch self {
            case .notCoverageData: "The file is not xccov output."
            case .noFiles: "The coverage data names no source files of this project."
            }
        }
    }

    public static func parse(
        archive: Data, report: Data?, name: String,
        options: LLVMCoverageJSONParser.Options = LLVMCoverageJSONParser.Options()
    ) throws -> JavaCoverageReport {
        let linesByFile: [String: [LineEntry]]
        do {
            linesByFile = try JSONDecoder().decode([String: [LineEntry]].self, from: archive)
        } catch {
            throw ParseError.notCoverageData
        }
        var reportFiles: [String: ReportFile] = [:]
        if let report {
            let decoded: Report
            do {
                decoded = try JSONDecoder().decode(Report.self, from: report)
            } catch {
                throw ParseError.notCoverageData
            }
            for target in decoded.targets ?? [] {
                for file in target.files ?? [] {
                    guard let path = file.path else { continue }
                    reportFiles[path] = file
                }
            }
        }
        let root = options.projectRoot?.resolvingSymlinksInPath().standardizedFileURL.path

        var byModule: [String: [JavaCoverageSourceFile]] = [:]
        for path in linesByFile.keys.sorted() {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard let entries = linesByFile[path],
                  let place = LLVMCoverageJSONParser.place(of: resolved, root: root, options: options)
            else { continue }
            let lines = lines(from: entries)
            var totals = JavaCoverageTotals()
            for line in lines {
                totals.lines.covered += line.status == .missed ? 0 : 1
                totals.lines.missed += line.status == .missed ? 1 : 0
            }
            if let file = reportFiles[path] {
                let covered = file.functions?.filter { ($0.executionCount ?? 0) > 0 }.count ?? 0
                let total = file.functions?.count ?? 0
                totals.methods = JavaCoverageCounter(missed: max(total - covered, 0), covered: covered)
                totals.instructions = JavaCoverageCounter(
                    missed: max(file.executableLines - file.coveredLines, 0), covered: file.coveredLines
                )
            }
            totals.classes = totals.lines.covered > 0 ? JavaCoverageCounter(covered: 1) : JavaCoverageCounter(missed: 1)
            byModule[place.module, default: []].append(JavaCoverageSourceFile(
                name: place.name, packageName: place.module, url: URL(fileURLWithPath: resolved),
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

    // MARK: - Lines

    /// Covered when the count ran, missed when it did not, partial when a subrange never ran.
    static func lines(from entries: [LineEntry]) -> [JavaCoverageLine] {
        var result: [JavaCoverageLine] = []
        for entry in entries where entry.isExecutable {
            if entry.executionCount == 0 {
                result.append(JavaCoverageLine(number: entry.line, missedInstructions: 1, coveredInstructions: 0))
            } else if entry.subranges?.contains(where: { $0.executionCount == 0 }) ?? false {
                result.append(JavaCoverageLine(number: entry.line, missedInstructions: 1, coveredInstructions: 1))
            } else {
                result.append(JavaCoverageLine(number: entry.line, missedInstructions: 0, coveredInstructions: 1))
            }
        }
        return result
    }

    // MARK: - Format

    struct Subrange: Decodable {
        var column: Int = 0
        var executionCount: Int = 0
        var length: Int = 0
    }

    struct LineEntry: Decodable {
        var line: Int = 0
        var isExecutable: Bool = false
        var executionCount: Int = 0
        var subranges: [Subrange]?

        enum CodingKeys: String, CodingKey {
            case line, isExecutable, executionCount, subranges
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            line = (try? container.decode(Int.self, forKey: .line)) ?? 0
            isExecutable = (try? container.decode(Bool.self, forKey: .isExecutable)) ?? false
            executionCount = (try? container.decode(Int.self, forKey: .executionCount)) ?? 0
            subranges = try? container.decode([Subrange].self, forKey: .subranges)
        }
    }

    private struct ReportFunction: Decodable {
        var executionCount: Int?
    }

    private struct ReportFile: Decodable {
        var coveredLines: Int = 0
        var executableLines: Int = 0
        var functions: [ReportFunction]?
        var path: String?

        enum CodingKeys: String, CodingKey {
            case coveredLines, executableLines, functions, path
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            coveredLines = (try? container.decode(Int.self, forKey: .coveredLines)) ?? 0
            executableLines = (try? container.decode(Int.self, forKey: .executableLines)) ?? 0
            functions = try? container.decode([ReportFunction].self, forKey: .functions)
            path = try? container.decode(String.self, forKey: .path)
        }
    }

    private struct ReportTarget: Decodable {
        var files: [ReportFile]?
    }

    private struct Report: Decodable {
        var targets: [ReportTarget]?
    }
}
