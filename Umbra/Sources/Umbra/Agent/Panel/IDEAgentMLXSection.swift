import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The on-device (MLX) model picker, context picker and availability notice. Extracted from
/// `IDEAgentSettingsView` so the settings form stays a composition of subviews.
struct IDEAgentMLXSection: View {
    @Bindable var settings: IDEAgentSettings
    let manageModels: () -> Void

    var body: some View {
        let store = IDELocalModelsStore.shared
        Picker("Model", selection: $settings.model) {
            if settings.model.isEmpty { Text("Choose…").tag("") }
            ForEach(store.installed) { model in
                let info = store.info(for: model)
                Text(LocalModelFormat.shortName(model.id) + (info.hasChatTemplate && !info.supportsTools ? " (no tool support)" : ""))
                    .tag(model.id)
                    .disabled(info.hasChatTemplate && !info.supportsTools)
            }
            if !settings.model.isEmpty, settings.selectedMLXModel == nil { Text(settings.model).tag(settings.model) }
        }
        Button("Manage On-Device Models…", action: manageModels)
        Label("Runs on this Mac's GPU. Nothing is sent anywhere.", systemImage: "lock.shield")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
        Picker("Context", selection: $settings.localContextLength) {
            ForEach(IDEAgentSettings.contextChoices, id: \.self) { Text(IDEAgentFormat.tokens($0)).tag($0) }
        }
        let status = MLXAvailability.currentStatus()
        if status != .available {
            Text(MLXAvailability.message(for: status)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        }
    }
}
