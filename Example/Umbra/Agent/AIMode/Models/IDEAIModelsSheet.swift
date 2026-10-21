import AgentKit
import SwiftUI

/// Manage Models: the Ollama models installed (pull and delete), the on-device ones, and the keys and
/// model names of the hosted providers. Changes apply as they are made.
struct IDEAIModelsSheet: View {
    let settings: IDEAgentSettings
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.ollama

    enum Tab: String, CaseIterable, Identifiable {
        case ollama = "Ollama"
        case onDevice = "On This Mac"
        case providers = "Providers"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Models").font(IDEAppearance.Typography.titlebarTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .foregroundStyle(IDEAppearance.ColorToken.foreground)
            .padding(IDEAppearance.Spacing.md)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.bottom, IDEAppearance.Spacing.sm)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .ollama: IDEAIOllamaTab(settings: settings)
                    case .onDevice: IDEAIOnDeviceTab(settings: settings)
                    case .providers: IDEAIProvidersTab(settings: settings)
                    }
                }
                .padding(IDEAppearance.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .background(IDEAppearance.ColorToken.panel)
    }
}

// MARK: - Ollama

private struct IDEAIOllamaTab: View {
    let settings: IDEAgentSettings
    @State private var store = IDEOllamaModelsStore.shared
    @State private var nameDraft = ""
    @State private var deleting: OllamaModel?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Address").font(IDEAppearance.Typography.sectionHeader)
                TextField("http://localhost:11434", text: Binding(
                    get: { settings.baseURL(for: .ollama) },
                    set: { settings.setBaseURL($0, for: .ollama) }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await settings.refreshOllamaModels(adjustSelection: false) } }
                Text("Ollama must be running. Models run on this Mac; nothing is sent anywhere.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                HStack {
                    Text("Installed").font(IDEAppearance.Typography.sectionHeader)
                    Spacer()
                    if settings.isLoadingOllamaModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await settings.refreshOllamaModels(adjustSelection: false) } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Reload the installed models")
                    }
                }
                if settings.ollamaModels.isEmpty {
                    Text(settings.ollamaError ?? "No models installed. Pull one below.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                ForEach(settings.ollamaModels) { model in
                    row(model)
                }
            }

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                Text("Pull a model").font(IDEAppearance.Typography.sectionHeader)
                HStack {
                    TextField("e.g. qwen3:8b", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pull)
                        .disabled(store.isPulling)
                    Button("Pull", action: pull)
                        .disabled(store.isPulling || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let name = store.pullingName {
                    VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                        if let fraction = store.progress?.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        HStack {
                            Text("\(name): \(store.progress?.status ?? "starting")")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                            Spacer()
                            Button("Cancel", action: store.cancelPull).controlSize(.small)
                        }
                    }
                }
                if let error = store.error {
                    Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
                }
                Text("Browse the library at ollama.com/library. The download resumes if it is cancelled.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .task { await settings.refreshOllamaModels(adjustSelection: false) }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let name = deleting?.name { Task { await store.delete(name) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The model is removed from this Mac. Pull it again to get it back.")
        }
    }

    private func pull() {
        store.pull(nameDraft)
        if store.isPulling { nameDraft = "" }
    }

    private func row(_ model: OllamaModel) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(IDEAppearance.Typography.body).foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(detail(model)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer()
            if store.deletingName == model.name {
                ProgressView().controlSize(.small)
            } else {
                Button { deleting = model } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete \(model.name)")
                    .accessibilityLabel("Delete \(model.name)")
            }
        }
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    private func detail(_ model: OllamaModel) -> String {
        var parts = [model.parameterSize, model.quantization].compactMap { $0 }
        if model.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)) }
        var abilities: [String] = []
        if model.supportsTools { abilities.append("tools") }
        if model.supportsThinking { abilities.append("thinking") }
        if model.supportsVision { abilities.append("vision") }
        if !abilities.isEmpty { parts.append(abilities.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - On this Mac

private struct IDEAIOnDeviceTab: View {
    let settings: IDEAgentSettings
    @State private var isPresented = false
    private var store: IDELocalModelsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Label("Runs on this Mac's GPU. Nothing is sent anywhere.", systemImage: "lock.shield")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if store.installed.isEmpty {
                Text("No models downloaded.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(store.installed) { model in
                HStack {
                    Text(model.id).font(IDEAppearance.Typography.body).foregroundStyle(IDEAppearance.ColorToken.foreground)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .padding(IDEAppearance.Spacing.sm)
                .background(IDEAppearance.ColorToken.card)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            }
            Button("Download and Manage On-Device Models…") { isPresented = true }
        }
        .task { store.prepareIfNeeded() }
        .sheet(isPresented: $isPresented) { IDELocalModelsView(store: .shared, settings: settings) }
    }
}

// MARK: - Providers

private struct IDEAIProvidersTab: View {
    let settings: IDEAgentSettings

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            IDEAIProviderSection(settings: settings, provider: .anthropic, modelHint: "claude-opus-5-5")
            IDEAIProviderSection(settings: settings, provider: .openAIResponses, modelHint: "gpt-5")
            Text("Keys are kept in the Keychain, one per address. The first message to an address asks before anything is sent. Endpoints that speak the OpenAI Chat Completions protocol, and external agents, are set up in Settings ▸ Agent.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

private struct IDEAIProviderSection: View {
    let settings: IDEAgentSettings
    let provider: IDEAgentProvider
    let modelHint: String
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                Text(provider == .anthropic ? "Anthropic" : "OpenAI").font(IDEAppearance.Typography.sectionHeader)
                Spacer()
                if settings.hasAPIKey(for: provider) {
                    Label("Key saved", systemImage: "checkmark.seal")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            TextField("Model (\(modelHint))", text: Binding(
                get: { settings.model(for: provider) },
                set: { settings.setModel($0, for: provider) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                SecureField(settings.hasAPIKey(for: provider) ? "Saved in the Keychain" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasAPIKey(for: provider) {
                    Button("Remove") { settings.removeAPIKey(for: provider) }
                }
            }
            if let error = settings.keyError {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    private func save() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        settings.saveAPIKey(key, for: provider)
        keyDraft = ""
    }
}
