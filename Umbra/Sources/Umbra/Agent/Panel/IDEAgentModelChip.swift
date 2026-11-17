import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The model this chat uses. Opens agent settings, where the model and provider are chosen.
struct IDEAgentModelChip: View {
    let settings: IDEAgentSettings
    let openSettings: () -> Void

    private var title: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? settings.provider.title : model
    }

    var body: some View {
        Button(action: openSettings) {
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 180)
        .help(settings.provider.title)
        .accessibilityLabel("Model: \(title)")
    }
}
