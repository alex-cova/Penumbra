import AppKit
import JavaIntelligence
import Observation
import Penumbra

/// What a finished coverage run left: the parsed report and what is needed to look at it again
/// (export it as HTML) and to place it (which run, which tasks).
struct IDECoverageSnapshot {
    var report: JavaCoverageReport
    var runID: String
    /// The configuration that ran, as the picker names it.
    var label: String
    var date: Date
    var tasks: [String]
    var runDirectory: URL
    var executionFiles: [URL]
    var classDirectories: [URL]
    var sourceDirectories: [URL]
    /// The JaCoCo tools a Java run was made with; nil for a Swift run, which has no HTML or XML export.
    var java: URL?
    var cliJar: URL?

    var supportsJaCoCoExports: Bool { java != nil && cliJar != nil }
}

/// One window's coverage: the snapshot of the last run, which files' colours can still be trusted,
/// and the bands the editor paints.
///
/// The editor only reads (`bands(forFile:)`); the report is made off the main actor and published
/// here, so nothing in typing waits on it. A file's bands are dropped the first time its buffer is
/// edited after the run (and from the start for a buffer that was already dirty), because a colour
/// on a line the run never saw is worse than none. The numbers stay in the tool window.
@MainActor
@Observable
final class IDECoverageController {
    private(set) var snapshot: IDECoverageSnapshot?
    /// "Building coverage report…" while the CLI runs.
    private(set) var progressMessage: String?
    /// Why the last run produced no report, kept until the next run.
    private(set) var failureMessage: String?
    /// Standardized paths of files whose buffer no longer matches what ran.
    private(set) var staleFiles: Set<String> = []
    /// Bumped when the set of painted bands changes: the window repaints on it.
    private(set) var generation = 0

    // Panel state
    var filterText = ""
    /// Hide classes at or above this percentage; `nil` shows everything.
    var maximumPercent: Int?

    var hasContent: Bool { snapshot != nil || progressMessage != nil || failureMessage != nil }
    var isBuilding: Bool { progressMessage != nil }

    func beginReport(message: String) {
        progressMessage = message
        failureMessage = nil
    }

    func fail(_ message: String) {
        progressMessage = nil
        failureMessage = message
    }

    func publish(_ snapshot: IDECoverageSnapshot, staleFiles: Set<String> = []) {
        self.snapshot = snapshot
        self.staleFiles = staleFiles
        progressMessage = nil
        failureMessage = nil
        generation += 1
    }

    func clear() {
        guard snapshot != nil || failureMessage != nil || progressMessage != nil else { return }
        snapshot = nil
        staleFiles = []
        progressMessage = nil
        failureMessage = nil
        generation += 1
    }

    // MARK: - What the editor paints

    /// The bands for `url`, none when it is not in the report or its buffer has moved on.
    func bands(forFile url: URL?) -> [JavaCoverageBand] {
        guard let url, let snapshot else { return [] }
        let path = url.standardizedFileURL.path
        guard !staleFiles.contains(path), let file = snapshot.report.sourceFile(at: url) else { return [] }
        return file.bands
    }

    /// Whether `url` has coverage that is still shown.
    func hasLiveCoverage(forFile url: URL?) -> Bool {
        guard let url, let snapshot else { return false }
        return !staleFiles.contains(url.standardizedFileURL.path) && snapshot.report.sourceFile(at: url) != nil
    }

    /// An edit to the buffer of `url`. Cheap after the first one. `true` when its bands just went.
    @discardableResult
    func noteEdit(file url: URL?) -> Bool {
        guard let url, snapshot != nil else { return false }
        let path = url.standardizedFileURL.path
        guard !staleFiles.contains(path), snapshot?.report.sourceFile(at: url) != nil else { return false }
        staleFiles.insert(path)
        generation += 1
        return true
    }

    // MARK: - Painting

    /// `LineBackground`s for `bands`, in the colours of a light or dark editor.
    static func lineBackgrounds(for bands: [JavaCoverageBand], darkTheme: Bool) -> [LineBackground] {
        guard !bands.isEmpty else { return [] }
        let colors = Colors(darkTheme: darkTheme)
        return bands.map {
            LineBackground(line: $0.lines.lowerBound, lineCount: $0.lines.count, color: colors.color(for: $0.status))
        }
    }

    struct Colors {
        let covered: CGColor
        let partial: CGColor
        let missed: CGColor

        init(darkTheme: Bool) {
            // Low alpha so syntax colours stay readable; a touch stronger on a light theme, where
            // the same alpha of a saturated colour reads weaker against white.
            let alpha: CGFloat = darkTheme ? 0.16 : 0.20
            covered = NSColor.systemGreen.withAlphaComponent(alpha).cgColor
            partial = NSColor.systemYellow.withAlphaComponent(alpha + 0.04).cgColor
            missed = NSColor.systemRed.withAlphaComponent(alpha + 0.02).cgColor
        }

        func color(for status: JavaLineCoverage) -> CGColor {
            switch status {
            case .covered: return covered
            case .partial: return partial
            case .missed: return missed
            }
        }
    }

    // MARK: - The tool window's rows

    struct ClassRow: Identifiable {
        var id: String { binaryName }
        var binaryName: String
        var displayName: String
        var linePercent: Int?
        var branchPercent: Int?
        var methodPercent: Int?
        var lines: JavaCoverageCounter
        var sourceURL: URL?
        var firstMissedLine: Int?
    }

    struct PackageRow: Identifiable {
        var id: String { name }
        var name: String
        var linePercent: Int?
        var classes: [ClassRow]
    }

    /// Packages and classes the filters let through, worst coverage first within a package.
    var packageRows: [PackageRow] {
        guard let snapshot else { return [] }
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [PackageRow] = []
        for package in snapshot.report.packages {
            let files = Dictionary(package.sourceFiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var classes: [ClassRow] = []
            for item in package.classes {
                let linePercent = item.totals.lines.percent
                if let maximumPercent, let linePercent, linePercent >= maximumPercent { continue }
                let display = (package.name.isEmpty ? "" : package.name + ".") + item.displayName
                if !query.isEmpty, !display.lowercased().contains(query) { continue }
                let file = item.sourceFileName.flatMap { files[$0] }
                classes.append(ClassRow(
                    binaryName: item.binaryName,
                    displayName: item.displayName,
                    linePercent: linePercent,
                    branchPercent: item.totals.branches.percent,
                    methodPercent: item.totals.methods.percent,
                    lines: item.totals.lines,
                    sourceURL: file?.url,
                    firstMissedLine: file?.lines.first { $0.status != .covered }?.number
                ))
            }
            guard !classes.isEmpty else { continue }
            classes.sort { ($0.linePercent ?? 101, $0.displayName) < ($1.linePercent ?? 101, $1.displayName) }
            rows.append(PackageRow(
                name: package.name.isEmpty ? "(default package)" : package.name,
                linePercent: package.totals.lines.percent,
                classes: classes
            ))
        }
        return rows.sorted { ($0.linePercent ?? 101, $0.name) < ($1.linePercent ?? 101, $1.name) }
    }

    /// `73% lines · 61% branches · 12 classes`.
    var summary: String? {
        guard let snapshot else { return nil }
        let totals = snapshot.report.totals
        var parts: [String] = []
        if let lines = totals.lines.percent { parts.append("\(lines)% lines") }
        if let branches = totals.branches.percent { parts.append("\(branches)% branches") }
        if let methods = totals.methods.percent { parts.append("\(methods)% methods") }
        parts.append("\(snapshot.report.packages.reduce(0) { $0 + $1.classes.count }) classes")
        return parts.joined(separator: " · ")
    }
}
