import SwiftUI

/// The external agent's model, from the `models` it advertised (`session/set_model`). Agents that
/// offer the model as a config option use `IDEACPConfigChip` instead, and an agent that advertised
/// neither shows no model control at all.
struct IDEACPModelChip: View {
    let conversation: IDEAgentConversation

    private var title: String {
        let current = conversation.acpAvailableModels.first { $0.modelId == conversation.acpCurrentModelID }
        return current?.name ?? conversation.acpCurrentModelID ?? "Model"
    }

    var body: some View {
        Menu {
            ForEach(conversation.acpAvailableModels, id: \.modelId) { model in
                Button {
                    conversation.setACPModel(model.modelId)
                } label: {
                    if model.modelId == conversation.acpCurrentModelID {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
                .help(model.description ?? model.modelId)
            }
        } label: {
            Label(title, systemImage: "cpu")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 200)
        .fixedSize(horizontal: false, vertical: true)
        .help("The model this agent uses. The list is the one the agent advertised.")
        .accessibilityLabel("Agent model: \(title)")
    }
}
