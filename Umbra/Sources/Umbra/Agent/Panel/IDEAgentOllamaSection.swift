import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The Ollama model picker, reload button and context picker. Extracted from
/// `IDEAgentSettingsView` so the settings form stays a composition of subviews.
struct IDEAgentOllamaSection: View {
    @Bindable var settings: IDEAgentSettings

    var body: some View {
        HStack {
            Picker("Model", selection: $settings.model) {
                if settings.model.isEmpty { Text("Choose…").tag("") }
                ForEach(settings.ollamaModels) { model in
                    Text(IDEAgentOllamaLabel.title(model)).tag(model.name).disabled(!model.supportsTools)
                }
                if !settings.model.isEmpty, settings.selectedOllamaModel == nil { Text(settings.model).tag(settings.model) }
            }
            if settings.isLoadingOllamaModels {
                ProgressView().controlSize(.small)
            } else {
                IDEIconButton(systemImage: "arrow.clockwise", help: "Reload the installed models") {
                    Task { await settings.refreshOllamaModels() }
                }
                .ideIconButtonSize(.compact)
            }
        }
        if let error = settings.ollamaError {
            Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        } else if let info = settings.selectedOllamaModel, !info.supportsTools {
            Text("This model does not support tool calling, so the agent cannot use it.")
                .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        }
        Picker("Context", selection: $settings.localContextLength) {
            ForEach(IDEAgentSettings.contextChoices, id: \.self) { Text(IDEAgentFormat.tokens($0)).tag($0) }
        }
        Text("A larger window needs more memory and slows the first reply. The model's own maximum is \(settings.selectedOllamaModel?.contextLength.map(IDEAgentFormat.tokens) ?? "unknown"); the request uses \(IDEAgentFormat.tokens(settings.effectiveContextLength)).")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }
}
