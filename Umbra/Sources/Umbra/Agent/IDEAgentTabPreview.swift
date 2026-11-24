import AgentKit
import Foundation

/// What a chat tab's tooltip says: its title, what it is doing, its last reply and what it changed and
/// cost. A tab not read yet (restored, never shown) is described from its saved summary and is not
/// loaded for it.
@MainActor
enum IDEAgentTabPreview {
    static func text(for conversation: IDEAgentConversation, saved: SessionSummary?, now: Date = Date()) -> String {
        if conversation.pendingLoadID != nil {
            var lines = [conversation.title]
            if let saved {
                var parts = ["\(saved.messageCount) \(saved.messageCount == 1 ? "message" : "messages")",
                             "updated " + relative(saved.updatedAt, now: now)]
                if let cost = saved.cost, cost > 0 { parts.append("~" + IDEAgentPrices.format(cost)) }
                lines.append(parts.joined(separator: " · "))
            }
            lines.append("Not opened since Umbra started")
            return lines.joined(separator: "\n")
        }
        return make(
            title: conversation.title, status: status(of: conversation, now: now),
            lastReply: conversation.entries.last { $0.kind == .assistant && !$0.text.isEmpty }?.text,
            filesChanged: IDEAIChangedFiles.summarize(conversation.entries).filter { !$0.isReverted }.count,
            cost: conversation.cost)
    }

    /// The tooltip from its parts; pure, for tests.
    static func make(title: String, status: String?, lastReply: String?, filesChanged: Int, cost: Double?) -> String {
        var lines = [title]
        if let status { lines.append(status) }
        if let lastReply {
            let reply = lastReply.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " ")
            lines.append("“" + (reply.count <= 200 ? reply : String(reply.prefix(199)) + "…") + "”")
        }
        var footer: [String] = []
        if filesChanged > 0 { footer.append("\(filesChanged) \(filesChanged == 1 ? "file" : "files") changed") }
        if let cost, cost > 0 { footer.append("~" + IDEAgentPrices.format(cost)) }
        if !footer.isEmpty { lines.append(footer.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    static func status(of conversation: IDEAgentConversation, now: Date) -> String? {
        if let entry = conversation.pendingDecision {
            if let request = entry.approval {
                return request.diff == nil ? "Waiting for your approval: \(request.command)" : "Waiting for you to approve an edit"
            }
            if let question = entry.question?.question { return "Asking: \(question)" }
            if entry.plan != nil { return "Waiting for you to approve the plan" }
            return "Waiting for you"
        }
        if conversation.retryState != nil { return "Waiting to retry the request" }
        if conversation.isRunning { return conversation.status.map { "Working · \($0)" } ?? "Working" }
        if conversation.isUnread { return "New reply" }
        if let last = conversation.lastActivity { return "Last active " + relative(last, now: now) }
        return conversation.isEmpty ? "New chat" : nil
    }

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
