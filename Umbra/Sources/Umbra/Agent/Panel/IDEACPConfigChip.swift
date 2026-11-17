import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// Options the connected agent advertised. A select option can be changed. An option
/// with no advertised values is shown as text, so Umbra does not invent a model list.
struct IDEACPConfigChip: View {
    let conversation: IDEAgentConversation

    var body: some View {
        Menu {
            ForEach(conversation.acpDisplayedConfigOptions, id: \.id) { option in
                let choices = option.selectableChoices
                if choices.isEmpty {
                    Text("\(option.name): \(option.currentValueDescription ?? "—")")
                } else {
                    Menu(option.name) {
                        ForEach(choices, id: \.value) { choice in
                            Button {
                                conversation.setACPConfig(id: option.id, value: choice.value)
                            } label: {
                                if choice.value == option.currentValueDescription {
                                    Label(choice.title, systemImage: "checkmark")
                                } else {
                                    Text(choice.title)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(label, systemImage: "slider.horizontal.3")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model, mode and other options this agent advertised.")
        .accessibilityLabel("Agent configuration: \(label)")
    }

    private var label: String {
        let model = conversation.acpConfigOptions.first {
            $0.id == "model" || $0.name.compare("model", options: .caseInsensitive) == .orderedSame
        }
        if let model, let value = model.currentValueDescription, !value.isEmpty { return value }
        return "Config"
    }
}
