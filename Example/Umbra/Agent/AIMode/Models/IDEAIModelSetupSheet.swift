import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The quiet replacement for a red setup line: opens the guided sheet.
struct IDEAISetupButton: View {
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Set up a model…", systemImage: "sparkles")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}

/// "Choose a model to get started": three ways to get one working, then **Use** picks it for the chat
/// or session that asked. Download one to this Mac, connect to Ollama, or add a hosted provider's key.
struct IDEAIModelSetupSheet: View {
    let settings: IDEAgentSettings
    let mode: IDEAIModelPickerMode
    let onUse: (IDEAIModelChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var option: Option?

    enum Option: String, CaseIterable, Identifiable {
        case apple, onDevice, ollama, apiKey
        var id: String { rawValue }

        var title: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .onDevice: "On This Mac"
            case .ollama: "Ollama"
            case .apiKey: "API Key"
            }
        }

        var detail: String {
            switch self {
            case .apple: "Apple's model, built into macOS. Nothing to download and no key."
            case .onDevice: "Private. Runs on this Mac's GPU; nothing is sent anywhere."
            case .ollama: "Use the models you run with Ollama."
            case .apiKey: "Use Claude, Muse from Meta, or OpenAI with your own key."
            }
        }

        var symbol: String {
            switch self {
            case .apple: "apple.logo"
            case .onDevice: "cpu"
            case .ollama: "server.rack"
            case .apiKey: "key"
            }
        }
    }

    private var isOnDeviceAvailable: Bool { MLXAvailability.currentStatus() == .available }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                    ForEach(Option.allCases) { item in
                        card(item)
                    }
                }
                .padding(IDEAppearance.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .background(IDEAppearance.ColorToken.panel)
        .onAppear {
            guard option == nil else { return }
            if settings.appleStatus(.onDevice) == .available {
                option = .apple
            } else {
                option = isOnDeviceAvailable ? .onDevice : .ollama
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Choose a model to get started").font(IDEAppearance.Typography.titlebarTitle)
                Text("Umbra needs a model to chat. Run one on this Mac, or connect to one you already use.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer()
            Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.md)
    }

    // MARK: - Cards

    private func card(_ item: Option) -> some View {
        let isOpen = option == item
        let isEnabled = item != .onDevice || isOnDeviceAvailable
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Button {
                option = item
            } label: {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(IDEAppearance.ColorToken.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(IDEAppearance.Typography.sectionHeader)
                        Text(item.detail)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    Spacer()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(item.title)

            if isOpen {
                Divider()
                switch item {
                case .apple: IDEAIAppleSetup(settings: settings, mode: mode, use: use)
                case .onDevice: IDEAIOnDeviceSetup(settings: settings, mode: mode, use: use)
                case .ollama: IDEAIOllamaSetup(settings: settings, mode: mode, use: use)
                case .apiKey: IDEAIAPIKeySetup(settings: settings, use: use)
                }
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .stroke(isOpen ? IDEAppearance.ColorToken.accent.opacity(0.6) : .clear, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func use(_ provider: IDEAgentProvider, _ model: String) {
        onUse(IDEAIModelChoice(provider: provider, model: model, reasoningEffort: settings.reasoningEffort(for: provider)))
        dismiss()
    }
}

// MARK: - Apple Intelligence

private struct IDEAIAppleSetup: View {
    let settings: IDEAgentSettings
    let mode: IDEAIModelPickerMode
    let use: (IDEAgentProvider, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            ForEach(AppleModelKind.allCases, id: \.self) { kind in
                row(kind)
            }
        }
    }

    private func row(_ kind: AppleModelKind) -> some View {
        let provider: IDEAgentProvider = kind == .onDevice ? .apple : .applePCC
        let status = settings.appleStatus(kind)
        let unavailable = AppleModelAvailability.message(for: status, kind: kind)
        let chatOnly = mode == .code && !settings.appleFitsCode(kind)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(IDEAIModelNames.display(provider: provider, model: provider.defaultModel)).font(IDEAppearance.Typography.body)
                Text(detail(kind, unavailable: unavailable, chatOnly: chatOnly))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(unavailable == nil ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .appleIntelligenceNotEnabled {
                Button("Open System Settings") { Self.openSettings() }
            }
            Button("Use") { use(provider, provider.defaultModel) }.disabled(unavailable != nil || chatOnly)
        }
    }

    private func detail(_ kind: AppleModelKind, unavailable: String?, chatOnly: Bool) -> String {
        if let unavailable { return unavailable }
        if chatOnly { return settings.codeHint(for: IDEAIModelChoice(provider: .apple, model: "system")) ?? "Too small for Code. Use it in Chat." }
        switch kind {
        case .onDevice: return "Private. Runs on this Mac; nothing is sent anywhere."
        case .privateCloudCompute: return "A larger model on Apple's servers. Your messages go to Apple, and Umbra asks first."
        }
    }

    /// Best effort: the Apple Intelligence pane when macOS knows the address, else System Settings itself.
    private static func openSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        if let pane, NSWorkspace.shared.open(pane) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

// MARK: - On This Mac

private struct IDEAIOnDeviceSetup: View {
    let settings: IDEAgentSettings
    let mode: IDEAIModelPickerMode
    let use: (IDEAgentProvider, String) -> Void
    @State private var isBrowsing = false
    private var store: IDELocalModelsStore { .shared }
    private var suggested: IDESuggestedLocalModel { IDESuggestedLocalModels.recommendedForChat }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            ForEach(store.installed) { model in
                let info = store.info(for: model)
                let lacksTools = mode == .code && info.hasChatTemplate && !info.supportsTools
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalModelFormat.shortName(model.id)).font(IDEAppearance.Typography.body)
                        Text(lacksTools ? "No tool support, which Code needs" : ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    Spacer()
                    Button("Use") { use(.mlx, model.id) }.disabled(lacksTools)
                }
            }

            if let download = store.download {
                downloadRow(download)
            } else if !store.installed.contains(where: { $0.id == suggested.id }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalModelFormat.shortName(suggested.id)).font(IDEAppearance.Typography.body)
                        Text("Suggested. \(suggested.blurb) About \(LocalModelFormat.bytes(suggested.approximateBytes)).")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    Spacer()
                    Button("Download") { store.startDownload(suggested.id) }
                        .disabled(!store.canStartDownload)
                }
            }
            if let error = store.downloadError {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }

            HStack {
                Button("Browse Hugging Face…") { isBrowsing = true }.controlSize(.small)
                Spacer()
                Text("Only the download uses the network, and only when you ask.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .task { store.prepareIfNeeded() }
        .sheet(isPresented: $isBrowsing) { IDELocalModelsView(store: .shared, settings: settings) }
    }

    private func downloadRow(_ download: IDELocalModelsStore.Download) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                Text(download.isPaused ? "Paused: \(download.id)" : "Downloading \(download.id)")
                    .font(IDEAppearance.Typography.body)
                    .lineLimit(1)
                Spacer()
                if download.isPaused {
                    Button("Resume") { store.resumeDownload() }.controlSize(.small)
                } else {
                    Button("Pause") { store.pauseDownload() }.controlSize(.small)
                }
                Button("Cancel") { store.cancelDownload() }.controlSize(.small)
            }
            if let fraction = download.progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(download.progress.detailText)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

// MARK: - Ollama

private struct IDEAIOllamaSetup: View {
    let settings: IDEAgentSettings
    let mode: IDEAIModelPickerMode
    let use: (IDEAgentProvider, String) -> Void
    @State private var store = IDEOllamaModelsStore.shared
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                TextField("http://localhost:11434", text: Binding(
                    get: { settings.baseURL(for: .ollama) },
                    set: { settings.setBaseURL($0, for: .ollama) }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { reload() }
                if settings.isLoadingOllamaModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry", action: reload).controlSize(.small)
                }
            }

            if settings.ollamaModels.isEmpty, !settings.isLoadingOllamaModels {
                Text(settings.ollamaError ?? "No models installed. Pull one below.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                if settings.ollamaError != nil, let url = URL(string: "https://ollama.com/download") {
                    Button("Get Ollama") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
            }

            ForEach(settings.ollamaModels) { model in
                let usable = mode == .chat || model.supportsTools
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(IDEAppearance.Typography.body)
                        if !usable {
                            Text("No tool support, which Code needs")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                    Spacer()
                    Button("Use") { use(.ollama, model.name) }.disabled(!usable)
                }
            }

            Divider()
            HStack {
                TextField("Pull a model, e.g. qwen3:8b", text: $nameDraft)
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
        }
        .task { reload() }
    }

    private func reload() { Task { await settings.refreshOllamaModels(adjustSelection: false) } }

    private func pull() {
        store.pull(nameDraft)
        if store.isPulling { nameDraft = "" }
    }
}

// MARK: - API key

private struct IDEAIAPIKeySetup: View {
    let settings: IDEAgentSettings
    let use: (IDEAgentProvider, String) -> Void
    @State private var provider = IDEAgentProvider.anthropic

    private var model: String { settings.model(for: provider).trimmingCharacters(in: .whitespaces) }
    private var isReady: Bool { settings.hasAPIKey(for: provider) && !model.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Picker("", selection: $provider) {
                Text("Anthropic").tag(IDEAgentProvider.anthropic)
                Text("Meta").tag(IDEAgentProvider.meta)
                Text("OpenAI").tag(IDEAgentProvider.openAIResponses)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            IDEAIProviderSection(
                settings: settings, provider: provider,
                modelHint: provider == .anthropic ? "claude-opus-5-5" : provider == .meta ? "muse-spark-1.3" : "gpt-5")
                .id(provider)

            HStack {
                Text("The key stays in the Keychain. Your first message asks before anything is sent.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
                Button("Use") { use(provider, model) }.disabled(!isReady)
            }
        }
    }
}
