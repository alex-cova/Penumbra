import SwiftUI

struct IDEDatabaseProductionPrompt: Identifiable {
    let id = UUID()
    let source: String
    let statements: [String]
    let decision: AsyncStream<Bool>.Continuation

    func resolve(_ approved: Bool) {
        decision.yield(approved)
        decision.finish()
    }
}

struct IDEDatabaseProductionSheet: View {
    let prompt: IDEDatabaseProductionPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Run on Production?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(IDEAppearance.ColorToken.error)
            Text("The batch includes SQL that may change \(prompt.source).")
            ScrollView {
                Text(prompt.statements.joined(separator: "\n\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Run on Production", role: .destructive) { finish(true) }
            }
        }
        .padding(20)
        .frame(width: 560, height: 300)
    }

    private func finish(_ approved: Bool) {
        prompt.resolve(approved)
        dismiss()
    }
}
