import AgentKit
import SwiftUI

/// One control for an external agent's model, reasoning effort and speed, like Codex's: the chip reads
/// "⚡ model  Effort ›", and its popover has the effort slider on top and the model list below.
///
/// Everything comes from what the agent advertised. The models are its `models` (`session/set_model`) or its
/// `model` config option (`session/set_config_option`); the effort stops are its `thought_level` option's levels
/// for the current model (Kiro sends new ones after a model change); the bolt appears only for an agent that
/// advertises a speed option. Nothing is offered that the agent did not list.
struct IDEACPModelPicker: View {
    let conversation: IDEAgentConversation

    @State private var isPresented = false

    struct Model: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        /// The price multiplier the agent advertised (Kiro's credits), shown on the row.
        var rate: ACPChoiceRate?
    }

    private var models: [Model] {
        if !conversation.acpAvailableModels.isEmpty {
            return conversation.acpAvailableModels.map { Model(id: $0.modelId, title: $0.name, detail: $0.description) }
        }
        return conversation.acpModelOption?.selectableChoiceDetails.map {
            Model(id: $0.value, title: $0.title, detail: $0.detail, rate: $0.rate)
        } ?? []
    }

    private var currentModelID: String? {
        conversation.acpAvailableModels.isEmpty
            ? conversation.acpModelOption?.currentValueDescription
            : conversation.acpCurrentModelID
    }

    private var modelTitle: String {
        guard let id = currentModelID else { return "Model" }
        return models.first { $0.id == id }?.title ?? id
    }

    private var effortTitle: String? { conversation.acpEffortOption?.currentChoiceTitle }

    private var isFast: Bool {
        ACPConfigOption.isFastValue(conversation.acpSpeedOption?.currentValueDescription)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                if isFast {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(IDEAppearance.ColorToken.accent)
                        .accessibilityHidden(true)
                }
                Text(modelTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let effortTitle {
                    Text(effortTitle)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
            }
            .font(IDEAppearance.Typography.caption)
            .frame(maxWidth: 220)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            IDEACPModelPickerPopover(conversation: conversation, models: models, currentModelID: currentModelID)
        }
        .help("Model, effort and speed. The choices are the ones this agent offers.")
        .accessibilityLabel("Agent model: \(modelTitle)\(effortTitle.map { ", effort \($0)" } ?? "")\(isFast ? ", fast" : "")")
    }
}

/// The picker's popover: speed and effort for the current model, then the models.
struct IDEACPModelPickerPopover: View {
    let conversation: IDEAgentConversation
    let models: [IDEACPModelPicker.Model]
    let currentModelID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if conversation.acpEffortOption != nil || conversation.acpSpeedOption != nil {
                header
                if let effort = conversation.acpEffortOption {
                    IDEACPEffortSlider(option: effort) { value in
                        conversation.setACPConfig(id: effort.id, value: value)
                    }
                }
                if !models.isEmpty { Divider() }
            }
            if !models.isEmpty {
                Text("Select model")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(models) { model in
                            row(model)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if let speed = conversation.acpSpeedOption {
                speedControl(speed)
            }
            Spacer(minLength: 0)
            Text(models.first { $0.id == currentModelID }?.title ?? currentModelID ?? "")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if let effort = conversation.acpEffortOption?.currentChoiceTitle {
                Text(effort)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: 0)
        }
    }

    /// Two values (off/on, standard/fast) toggle with the bolt; more get a menu.
    @ViewBuilder private func speedControl(_ speed: ACPConfigOption) -> some View {
        let choices = speed.selectableChoices
        let isFast = ACPConfigOption.isFastValue(speed.currentValueDescription)
        if choices.count == 2 {
            Button {
                let next = choices.first { $0.value != speed.currentValueDescription }?.value ?? choices[0].value
                conversation.setACPConfig(id: speed.id, value: next)
            } label: {
                Image(systemName: isFast ? "bolt.fill" : "bolt")
                    .foregroundStyle(isFast ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
            }
            .buttonStyle(.borderless)
            .help("\(speed.name): \(speed.currentChoiceTitle ?? "—"). Click to switch.")
            .accessibilityLabel("\(speed.name), \(speed.currentChoiceTitle ?? "")")
        } else {
            Menu {
                ForEach(choices, id: \.value) { choice in
                    Button(choice.title) { conversation.setACPConfig(id: speed.id, value: choice.value) }
                }
            } label: {
                Image(systemName: isFast ? "bolt.fill" : "bolt")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(speed.name): \(speed.currentChoiceTitle ?? "—")")
        }
    }

    private func row(_ model: IDEACPModelPicker.Model) -> some View {
        Button {
            select(model.id)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    if let detail = model.detail {
                        Text(detail)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: IDEAppearance.Spacing.sm)
                if let rate = model.rate {
                    Text(rate.label)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(rate.multiplier > 1 ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                        .help(rate.help)
                }
                Image(systemName: "checkmark")
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .opacity(model.id == currentModelID ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([model.detail ?? model.id, model.rate?.help].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel("\(model.title)\(model.rate.map { ", \($0.label) \($0.unit?.lowercased() ?? "rate")" } ?? "")\(model.id == currentModelID ? ", selected" : "")")
    }

    /// The popover stays open, so the effort stops for the new model can be picked right after.
    private func select(_ modelID: String) {
        guard modelID != currentModelID else { return }
        if !conversation.acpAvailableModels.isEmpty {
            conversation.setACPModel(modelID)
        } else if let option = conversation.acpModelOption {
            conversation.setACPConfig(id: option.id, value: modelID)
        }
    }
}

/// A slider with one stop per advertised level. The level is sent once, when the drag ends or a stop is clicked.
private struct IDEACPEffortSlider: View {
    let option: ACPConfigOption
    let commit: (String) -> Void

    @State private var position: Double = 0

    private var levels: [(value: String, title: String)] { option.selectableChoices }

    private var currentIndex: Int {
        levels.firstIndex { $0.value == option.currentValueDescription } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if levels.count > 1 {
                Slider(value: $position, in: 0...Double(levels.count - 1), step: 1) { editing in
                    guard !editing else { return }
                    send()
                }
                .accessibilityLabel(option.name)
                .accessibilityValue(levels[min(Int(position.rounded()), levels.count - 1)].title)
                HStack {
                    Text(levels.first?.title ?? "")
                    Spacer()
                    Text(levels.last?.title ?? "")
                }
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if let only = levels.first {
                Text("\(option.name): \(only.title)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .onAppear { position = Double(currentIndex) }
        .onChange(of: option.currentValueDescription) { position = Double(currentIndex) }
        .onChange(of: levels.map(\.value)) { position = Double(currentIndex) }
    }

    private func send() {
        let index = min(max(Int(position.rounded()), 0), levels.count - 1)
        guard levels[index].value != option.currentValueDescription else { return }
        commit(levels[index].value)
    }
}
