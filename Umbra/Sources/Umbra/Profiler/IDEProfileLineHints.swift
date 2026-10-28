import Foundation
import JavaIntelligence
import Observation
import Penumbra

/// What the editor shows beside Java code from the profile the user is looking at: each line's share
/// of the samples in the annotation column, and the hottest lines (by their own samples) tinted.
///
/// Pure bookkeeping: which file belongs to which class, and what text a line gets. The workspace
/// decides when to refresh and where the column and the bands go.
@MainActor
@Observable
final class IDEProfileLineHints {
    private(set) var profile: JavaLineProfile?
    /// The recording's name, for the tooltip.
    private(set) var title: String?
    private(set) var revision = 0

    /// Lines under this share of the samples get no label: a column of `0.0%` helps nobody.
    static let minimumShare = 0.005
    /// A line whose own samples are at least this share is tinted.
    static let heatShare = 0.01

    var isActive: Bool { profile?.isEmpty == false }

    func show(_ profile: JavaLineProfile, title: String) {
        self.profile = profile
        self.title = title
        revision += 1
    }

    func clear() {
        ticket += 1
        guard profile != nil else { return }
        profile = nil
        title = nil
        revision += 1
    }

    /// The costs are built off the main actor; a result is only taken if nothing newer was asked for.
    @ObservationIgnored private var ticket = 0

    func beginUpdate() -> Int {
        ticket += 1
        return ticket
    }

    @discardableResult
    func finishUpdate(ticket: Int, profile: JavaLineProfile, title: String) -> Bool {
        guard ticket == self.ticket else { return false }
        show(profile, title: title)
        return true
    }

    /// `app.Order` for `…/src/main/java/app/Order.java` with that source root, the longest root
    /// that contains the file winning (a nested module's root over its parent's).
    static func className(forFile url: URL, roots: [URL]) -> String? {
        let path = url.standardizedFileURL.path
        guard path.hasSuffix(".java") else { return nil }
        var best: String?
        for root in roots {
            let prefix = root.standardizedFileURL.path.hasSuffix("/")
                ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count).dropLast(".java".count))
            if best == nil || relative.count < best!.count { best = relative }
        }
        return best?.replacingOccurrences(of: "/", with: ".")
    }

    /// The costs of the lines of `url`, or `nil` when the profile has nothing in that file.
    /// A Swift file is keyed by its recorded path (a Swift frame's "class" is its binary, so
    /// class keying says nothing); a Java file by its class under the source roots.
    func lines(forFile url: URL, roots: [URL]) -> [Int32: JavaLineProfile.Cost]? {
        guard let profile, profile.totalSamples > 0 else { return nil }
        if url.pathExtension == "swift" {
            let lines = linesForSwiftFile(url)
            return lines.isEmpty ? nil : lines
        }
        guard let className = Self.className(forFile: url, roots: roots) else { return nil }
        let lines = profile.lines(ofClass: className)
        return lines.isEmpty ? nil : lines
    }

    /// The recorded costs for a Swift file: the exact path first, else the profile path with the
    /// same file name when it is the only one (a recording made elsewhere keeps its own root).
    private func linesForSwiftFile(_ url: URL) -> [Int32: JavaLineProfile.Cost] {
        guard let profile else { return [:] }
        let exact = profile.lines(ofFile: url.standardizedFileURL.path)
        if !exact.isEmpty { return exact }
        let name = url.lastPathComponent
        let candidates = profile.filePaths.filter { ($0 as NSString).lastPathComponent == name }
        guard candidates.count == 1, let only = candidates.first else { return [:] }
        return profile.lines(ofFile: only)
    }

    /// One entry per line of the file (`lineCount`), the label being the line's share of all samples.
    func annotations(forFile url: URL, roots: [URL], lineCount: Int) -> [GutterAnnotation?]? {
        guard let profile, let lines = lines(forFile: url, roots: roots) else { return nil }
        let total = Double(profile.totalSamples)
        var result = [GutterAnnotation?](repeating: nil, count: max(lineCount, 0))
        for (line, cost) in lines {
            let row = Int(line) - 1
            guard row >= 0, row < result.count else { continue }
            let share = Double(cost.totalCount) / total
            guard share >= Self.minimumShare else { continue }
            let own = Double(cost.selfCount) / total
            var tooltip = String(format: "%.1f%% of the samples (%@)", share * 100, cost.totalCount.formatted())
            if cost.selfCount > 0 { tooltip += String(format: "\nthe line itself: %.1f%%", own * 100) }
            if let title { tooltip += "\n" + title }
            // Each line has its own id, or neighbours with the same text would show it once.
            result[row] = GutterAnnotation(id: Int(line), text: String(format: "%.1f%%", share * 100), tooltip: tooltip)
        }
        return result
    }

    /// Lines to tint and how much (0...1 of the hottest line's own share), for the file.
    func heat(forFile url: URL, roots: [URL]) -> [(line: Int, intensity: Double)] {
        guard let profile, let lines = lines(forFile: url, roots: roots) else { return [] }
        let total = Double(profile.totalSamples)
        let hot = lines.compactMap { line, cost -> (Int, Double)? in
            let share = Double(cost.selfCount) / total
            return share >= Self.heatShare ? (Int(line), share) : nil
        }
        guard let peak = hot.map(\.1).max() else { return [] }
        return hot.map { ($0.0, $0.1 / peak) }.sorted { $0.line < $1.line }
    }
}
