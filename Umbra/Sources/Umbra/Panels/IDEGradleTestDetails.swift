import Foundation
import JavaIntelligence
import SwiftUI

struct IDEGradleTestDetails: View {
    @Environment(IDEWorkspace.self) private var workspace
    let node: GradleTestSession.Node?
    let report: GradleTestReports.Row?
    let directory: URL?
    let status: String?
    let issues: Int
    let isRetry: Bool

    @State private var output = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                if let status { Text(status).foregroundStyle(IDEAppearance.ColorToken.muted) }
                if issues > 0 {
                    Text("\(issues) incomplete or unreadable event records")
                        .foregroundStyle(IDEAppearance.ColorToken.error)
                }
                if let node {
                    let event = node.event
                    Text([event.className, event.name].compactMap { $0 }.joined(separator: "."))
                        .font(IDEAppearance.Typography.body.weight(.semibold))
                    if let task = event.task { Text(task) }
                    Text(event.build)
                    Text(outcomeLabel(node.outcome))
                    if let duration = event.durationMs {
                        Text(Duration.milliseconds(duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .wide)))
                    }
                    if let failure = event.failure {
                        Text(failure.type).font(IDEAppearance.Typography.monoSmall)
                        if let message = failure.message { Text(message).font(IDEAppearance.Typography.monoSmall) }
                        if let expected = failure.expected, let actual = failure.actual {
                            HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
                                comparison("Expected", expected)
                                Divider()
                                comparison("Actual", actual)
                            }
                        }
                        if let trace = failure.stackTrace {
                            IDEStackTraceText(text: trace) { workspace.openGradleStackFrame($0, event: event) }
                        }
                    }
                    if !output.isEmpty {
                        Text("Test Output").font(IDEAppearance.Typography.caption.weight(.semibold))
                        Text(output).font(IDEAppearance.Typography.monoSmall)
                    }
                } else if let report {
                    Text("\(report.result.className).\(report.result.name)")
                        .font(IDEAppearance.Typography.body.weight(.semibold))
                    Text("\(report.task) · \(report.result.status.rawValue.capitalized) · Gradle XML report")
                    if let message = report.result.message { Text(message) }
                    if let trace = report.result.stackTrace {
                        IDEStackTraceText(text: trace) { workspace.openStackFrame($0) }
                    }
                    if let output = report.result.output { Text(output).font(IDEAppearance.Typography.monoSmall) }
                } else {
                    Text("Select a test or suite to inspect its results.")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .font(IDEAppearance.Typography.body)
            .textSelection(.enabled)
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: OutputRequest(directory: directory, id: node?.id, count: node?.output.count ?? 0)) {
            output = ""
            guard let node, let directory, !node.output.isEmpty else { return }
            let data = await Self.readOutput(directory, references: node.output)
            if !Task.isCancelled { output = data }
        }
    }

    private func comparison(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(IDEAppearance.Typography.caption.weight(.semibold))
            Text(value).font(IDEAppearance.Typography.monoSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeLabel(_ outcome: GradleTestEvent.Outcome) -> String {
        if isRetry, outcome == .failed { return "Failed on retry" }
        if isRetry, outcome == .passed { return "Passed on retry" }
        return outcome.rawValue.capitalized
    }

    private struct OutputRequest: Equatable {
        let directory: URL?
        let id: String?
        let count: Int
    }

    @concurrent private static func readOutput(_ directory: URL, references: [GradleTestEvent.Output]) async -> String {
        let fileURL = directory.appendingPathComponent("test-output.raw")
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? reader.close() }
        var bytes = Data()
        let limit = 32 * 1024
        var truncated = false
        for reference in references {
            if Task.isCancelled { return "" }
            let count = Int(min(UInt64(limit - bytes.count), reference.length))
            if count == 0 { truncated = true; break }
            do {
                try reader.seek(toOffset: reference.offset)
                if let part = try reader.read(upToCount: count) { bytes.append(part) }
                if UInt64(count) < reference.length { truncated = true; break }
            } catch { break }
        }
        return String(decoding: bytes, as: UTF8.self) + (truncated ? "\n[Output preview truncated]" : "")
    }
}
