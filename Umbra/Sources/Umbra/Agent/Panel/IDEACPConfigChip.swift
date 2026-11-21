import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// Options the connected agent advertised that no other chip shows. A select option can be changed. An option
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
            Image(systemName: "slider.horizontal.3")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Other options this agent advertised. The model, effort and speed are on the model picker.")
        .accessibilityLabel("Agent options")
    }
}
