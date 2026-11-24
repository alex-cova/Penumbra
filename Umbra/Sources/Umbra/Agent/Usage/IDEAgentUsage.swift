import AgentKit
import Foundation

/// One saved chat's usage, read from its file (`docs/harness/agent-harness-11.md`, item 1).
struct IDEAgentUsageRecord: Equatable, Sendable {
    var id: UUID
    var title: String
    var projectRoot: String
    var updatedAt: Date
    var usage: TokenUsage
    /// Tokens per model id. A chat saved before the split was kept puts its whole total under its model
    /// (or `IDEAgentUsageReport.unrecordedModel`).
    var byModel: [String: TokenUsage]
    /// What the chat recorded as it ran, from the price table of the time; nil when a turn had no known price.
    var cost: Double?

    var hasTokens: Bool { usage.inputTokens + usage.outputTokens > 0 }
}

/// Totals over saved chats: never re-priced, so a chat keeps the cost it recorded when it ran.
struct IDEAgentUsageReport: Equatable {
    static let unrecordedModel = "Model not recorded"

    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var chats: Int
        var usage: TokenUsage
        /// Sum of the costs that are known; nil when none is.
        var cost: Double?

        var cachedShare: Double? {
            usage.inputTokens > 0 ? Double(usage.cachedInputTokens) / Double(usage.inputTokens) : nil
        }
    }

    struct Day: Identifiable, Equatable {
        var id: Date { day }
        var day: Date
        var cost: Double
        var tokens: Int
    }

    var total = TokenUsage()
    var cost: Double = 0
    var chats = 0
    /// Chats with tokens and no recorded cost (local models, a model missing from the price table).
    var unpricedChats = 0
    var byModel: [Row] = []
    var byProject: [Row] = []
    var byDay: [Day] = []

    var cachedShare: Double? {
        total.inputTokens > 0 ? Double(total.cachedInputTokens) / Double(total.inputTokens) : nil
    }

    /// `days`: the period, ending today, whose days the chart shows even when empty; nil shows only days
    /// that have chats. A chat counts on the day it was last used, since that is all a saved file says.
    static func make(_ records: [IDEAgentUsageRecord], days: Int?, now: Date = Date(), calendar: Calendar = .current) -> IDEAgentUsageReport {
        var report = IDEAgentUsageReport()
        var models: [String: Row] = [:]
        var projects: [String: Row] = [:]
        var dayTotals: [Date: (cost: Double, tokens: Int)] = [:]
        for record in records where record.hasTokens {
            report.chats += 1
            report.total = report.total + record.usage
            if let cost = record.cost { report.cost += cost } else { report.unpricedChats += 1 }

            // The chat's cost goes to the model that did most of its work: helper models are priced at 0.
            let main = record.byModel.max { lhs, rhs in
                let left = lhs.value.inputTokens + lhs.value.outputTokens
                let right = rhs.value.inputTokens + rhs.value.outputTokens
                return left == right ? lhs.key > rhs.key : left < right
            }?.key
            for (model, usage) in record.byModel {
                let name = model.isEmpty ? unrecordedModel : model
                var row = models[name] ?? Row(id: name, name: name, chats: 0, usage: TokenUsage(), cost: nil)
                row.chats += 1
                row.usage = row.usage + usage
                if model == main, let cost = record.cost { row.cost = (row.cost ?? 0) + cost }
                models[name] = row
            }

            var project = projects[record.projectRoot]
                ?? Row(id: record.projectRoot, name: projectName(record.projectRoot), chats: 0, usage: TokenUsage(), cost: nil)
            project.chats += 1
            project.usage = project.usage + record.usage
            if let cost = record.cost { project.cost = (project.cost ?? 0) + cost }
            projects[record.projectRoot] = project

            let day = calendar.startOfDay(for: record.updatedAt)
            let earlier = dayTotals[day] ?? (0, 0)
            dayTotals[day] = (earlier.cost + (record.cost ?? 0), earlier.tokens + record.usage.inputTokens + record.usage.outputTokens)
        }
        let order: (Row, Row) -> Bool = { lhs, rhs in
            if (lhs.cost ?? 0) != (rhs.cost ?? 0) { return (lhs.cost ?? 0) > (rhs.cost ?? 0) }
            let left = lhs.usage.inputTokens + lhs.usage.outputTokens
            let right = rhs.usage.inputTokens + rhs.usage.outputTokens
            return left == right ? lhs.name < rhs.name : left > right
        }
        report.byModel = models.values.sorted(by: order)
        report.byProject = projects.values.sorted(by: order)
        if let days, days > 0 {
            let today = calendar.startOfDay(for: now)
            report.byDay = (0..<days).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let totals = dayTotals[day] ?? (0, 0)
                return Day(day: day, cost: totals.cost, tokens: totals.tokens)
            }
        } else {
            report.byDay = dayTotals.keys.sorted().map { Day(day: $0, cost: dayTotals[$0]!.cost, tokens: dayTotals[$0]!.tokens) }
        }
        return report
    }

    static func projectName(_ root: String) -> String {
        if root == IDEAIChatConversation.storeRoot { return "AI Chat" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }
}

/// Reads saved chats for the usage view, off the main actor. Only the usage fields are decoded into values
/// (the transcript is parsed past), files older than the period are not opened, and at most `maxFiles`
/// newest files are read.
enum IDEAgentUsageLoader {
    static let maxFiles = 5_000

    /// `projectRoot`: one project's chats, or every project's when nil.
    static func records(in store: SessionStore, projectRoot: String?, since: Date?) -> [IDEAgentUsageRecord] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let folders: [URL]
        if let projectRoot {
            folders = [store.projectDirectory(for: projectRoot)]
        } else {
            folders = ((try? manager.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: keys)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        var candidates: [(url: URL, modified: Date)] = []
        for folder in folders {
            // One level, like `SessionStore.listAll`: subfolders hold checkpoints, outputs and archives.
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            where url.pathExtension == "json" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if let since, modified < since { continue }
                candidates.append((url, modified))
            }
        }
        return candidates.sorted { $0.modified > $1.modified }.prefix(maxFiles).compactMap { candidate in
            guard let data = try? Data(contentsOf: candidate.url) else { return nil }
            return record(from: data, since: since)
        }
    }

    private struct SavedUsage: Decodable {
        var version: Int?
        var id: UUID
        var projectRoot: String
        var title: String
        var updatedAt: Date
        var totalUsage: TokenUsage?
        var host: Data?
    }

    static func record(from data: Data, since: Date? = nil) -> IDEAgentUsageRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedUsage.self, from: data),
              (saved.version ?? 1) <= SessionSnapshot.currentVersion
        else { return nil }
        if let since, saved.updatedAt < since { return nil }
        let usage = saved.totalUsage ?? TokenUsage()
        let transcript = IDEAgentSavedTranscript.decode(saved.host)
        var byModel = transcript.usageByModel
        if byModel.isEmpty, usage.inputTokens + usage.outputTokens > 0 {
            let model = transcript.modelChoice?.model ?? ""
            byModel = [model.isEmpty ? IDEAgentUsageReport.unrecordedModel : model: usage]
        }
        return IDEAgentUsageRecord(
            id: saved.id, title: saved.title, projectRoot: saved.projectRoot, updatedAt: saved.updatedAt,
            usage: usage, byModel: byModel, cost: transcript.cost)
    }
}
