import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// Manage the models that run on this Mac: what is installed, search and download from Hugging Face,
/// and what is loaded in memory.
struct IDELocalModelsView: View {
    let store: IDELocalModelsStore
    let settings: IDEAgentSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var tokenDraft = ""
    @State private var filter = IDELocalModelFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
                    if store.availability != .available { availabilityBanner }
                    installedSection
                    if let download = store.download { downloadSection(download) }
                    filterBar
                    suggestedSection
                    searchSection
                    footer
                }
                .padding(IDEAppearance.Spacing.md)
            }
        }
        .frame(width: 600, height: 620)
        .background(IDEAppearance.ColorToken.panel)
        .task { store.prepareIfNeeded(); await store.refreshMemory() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("On-Device Models").font(IDEAppearance.Typography.titlebarTitle)
            Spacer()
            if store.memoryBytes > 0 {
                Text("MLX memory: \(ByteCountFormatter.string(fromByteCount: Int64(store.memoryBytes), countStyle: .memory))")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.md)
    }

    private var availabilityBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(MLXAvailability.title(for: store.availability)).font(IDEAppearance.Typography.sectionHeader)
                Text(MLXAvailability.message(for: store.availability)).font(IDEAppearance.Typography.caption)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(IDEAppearance.ColorToken.error)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Installed").font(IDEAppearance.Typography.sectionHeader)
            if store.installed.isEmpty {
                Text("No models yet. Download a suggested one below, or search for another that supports tools.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(store.installed) { model in installedRow(model) }
            if let error = store.loadError {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
    }

    private func installedRow(_ model: InstalledLocalModel) -> some View {
        let info = store.info(for: model)
        let isUsed = settings.provider == .mlx && settings.model == model.id
        let isLoaded = store.loadedID == model.id
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalModelFormat.shortName(model.id)).font(IDEAppearance.Typography.body).lineLimit(1)
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Text(LocalModelFormat.owner(model.id))
                    Text("· \(LocalModelFormat.bytes(model.sizeBytes))")
                    if let context = info.contextLength { Text("· \(IDEAgentFormat.tokens(context)) context") }
                    toolsBadge(info)
                    if isLoaded { Text("· loaded").foregroundStyle(IDEAppearance.ColorToken.run) }
                }
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: 0)
            if isUsed {
                Label("Agent model", systemImage: "checkmark.circle.fill")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.run)
            } else {
                Button("Use for Agent") {
                    settings.provider = .mlx
                    settings.model = model.id
                }
                .controlSize(.small)
                .disabled(info.hasChatTemplate && !info.supportsTools)
                .help(info.hasChatTemplate && !info.supportsTools ? "This model's chat template does not take tools." : "Run the agent with this model")
            }
            if IDEPreferences.shared.inlineCompletionModelID == model.id {
                Label("Code completion", systemImage: "checkmark.circle.fill")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.run)
            } else {
                Button("Use for Code Completion") {
                    IDEPreferences.shared.inlineCompletionModelID = model.id
                    IDEPreferences.shared.inlineCompletionEnabled = true
                }
                .controlSize(.small)
            }
            Button(isLoaded ? "Unload" : "Load") {
                if isLoaded { store.unload() } else { Task { await store.load(model) } }
            }
            .controlSize(.small)
            .disabled(store.availability != .available || store.isLoading)
            Button { store.delete(model) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete from disk")
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    @ViewBuilder private func toolsBadge(_ info: MLXModelInfo) -> some View {
        if !info.hasChatTemplate {
            Text("· no chat template").foregroundStyle(IDEAppearance.ColorToken.error)
        } else if info.supportsTools {
            Text("· tools")
        } else {
            Text("· no tool support").foregroundStyle(IDEAppearance.ColorToken.error)
        }
    }

    // MARK: - Download

    private func downloadSection(_ download: IDELocalModelsStore.Download) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                Text(download.isPaused ? "Paused: \(download.id)" : "Downloading \(download.id)")
                    .font(IDEAppearance.Typography.sectionHeader)
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
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    // MARK: - Filters

    /// Precision and Parameters narrow the suggestions and the search results below.
    private var filterBar: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Picker("Precision", selection: $filter.precision) {
                Text("Any").tag(IDELocalModelFilter.Precision?.none)
                ForEach(IDELocalModelFilter.Precision.allCases) { Text($0.title).tag(IDELocalModelFilter.Precision?.some($0)) }
            }
            .help("Bits per weight. Fewer bits is smaller and faster, and loses some accuracy.")
            Picker("Parameters", selection: $filter.parameters) {
                Text("Any").tag(IDELocalModelFilter.Parameters?.none)
                ForEach(IDELocalModelFilter.Parameters.allCases) { Text($0.title).tag(IDELocalModelFilter.Parameters?.some($0)) }
            }
            .help("The model's size in billions of parameters")
            Spacer(minLength: 0)
            if filter.isActive {
                Button("Clear Filters") { filter = IDELocalModelFilter() }.controlSize(.small)
            }
        }
        .pickerStyle(.menu)
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
    }

    // MARK: - Suggested

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Suggested").font(IDEAppearance.Typography.sectionHeader)
            let shown = IDESuggestedLocalModels.all.filter(filter.matches)
            ForEach(shown) { suggested in suggestedRow(suggested) }
            if shown.isEmpty {
                Text("No suggestion has that precision and size.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let error = store.downloadError, store.download == nil {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
    }

    private func suggestedRow(_ suggested: IDESuggestedLocalModel) -> some View {
        let isInstalled = store.installed.contains { $0.id == suggested.id }
        let isDownloading = store.download?.id == suggested.id
        let fits = suggested.fitsMemory()
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalModelFormat.shortName(suggested.id)).font(IDEAppearance.Typography.body).lineLimit(1)
                Text(suggested.blurb).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Text("\(IDELocalModelFilter.sizeLabel(billions: suggested.parameterBillions)) · \(suggested.bits)-bit · about \(LocalModelFormat.bytes(suggested.approximateBytes))")
                    if let memory = suggested.recommendedMemoryGB {
                        Text("· \(memory) GB memory or more")
                            .foregroundStyle(fits ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                    }
                }
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: 0)
            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.run)
            } else if isDownloading {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { store.startDownload(suggested.id) }
                    .controlSize(.small)
                    .disabled(!store.canStartDownload)
                    .help(store.download == nil ? "Download from huggingface.co" : "One download at a time.")
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    // MARK: - Search

    private var searchSection: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Find a model").font(IDEAppearance.Typography.sectionHeader)
            HStack {
                TextField("Search Hugging Face for MLX models, e.g. Qwen2.5 Instruct", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                Button("Search") { Task { await store.search() } }.disabled(store.isSearching)
                if store.isSearching { ProgressView().controlSize(.small) }
            }
            Text("Only the search and the download use the network, and only when you ask. Running a model needs none.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let error = store.searchError {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }
            let shown = store.results.filter(filter.matches)
            ForEach(shown) { result in resultRow(result) }
            if filter.isActive, shown.count < store.results.count {
                Text(shown.isEmpty
                    ? "No result matches the filters. A model whose precision or size is not known is hidden while one is set."
                    : "\(store.results.count - shown.count) more hidden by the filters.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let selectedID, let result = store.results.first(where: { $0.id == selectedID }) { detailsPane(result) }
        }
    }

    private func resultRow(_ result: HFModelSummary) -> some View {
        Button {
            selectedID = result.id
            Task { await store.loadDetails(for: result.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.id).font(IDEAppearance.Typography.body).lineLimit(1)
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        if let billions = IDELocalModelFilter.billions(of: result) { Text(IDELocalModelFilter.sizeLabel(billions: billions)) }
                        if let bits = IDELocalModelFilter.bits(of: result) { Text("· \(bits)-bit") }
                        Text("· \(LocalModelFormat.compactCount(result.downloads)) downloads")
                        if result.isGated { Text("· gated").foregroundStyle(IDEAppearance.ColorToken.error) }
                    }
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                if store.installed.contains(where: { $0.id == result.id }) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(IDEAppearance.ColorToken.run)
                }
            }
            .padding(IDEAppearance.Spacing.sm)
            .background(selectedID == result.id ? IDEAppearance.ColorToken.controlHover : IDEAppearance.ColorToken.card)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
    }

    private func detailsPane(_ result: HFModelSummary) -> some View {
        let detail = store.details[result.id]
        let installed = store.installed.contains { $0.id == result.id }
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(result.id).font(IDEAppearance.Typography.sectionHeader)
            if let size = detail?.sizeBytes {
                Text("Downloads \(LocalModelFormat.bytes(size)) from huggingface.co and keeps it in the models folder.")
            } else if detail == nil {
                HStack { ProgressView().controlSize(.small); Text("Checking size and tool support…") }
            }
            if let supportsTools = detail?.supportsTools {
                Label(
                    supportsTools ? "The chat template takes tools, so the agent can use this model." : "The chat template does not take tools, so the agent cannot use this model. Code completion can still use it.",
                    systemImage: supportsTools ? "checkmark.seal" : "xmark.seal")
                    .foregroundStyle(supportsTools ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
            } else if detail != nil {
                Text("Could not check whether this model supports tools.").foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let error = detail?.error { Text(error).foregroundStyle(IDEAppearance.ColorToken.error) }
            if result.isGated && !store.hasToken {
                Text("This model is gated. Accept its license on huggingface.co and save a read token below.")
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            if let error = store.downloadError { Text(error).foregroundStyle(IDEAppearance.ColorToken.error) }
            HStack {
                Button(installed ? "Installed" : "Download") { store.startDownload(result.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(installed || !store.canStartDownload || (result.isGated && !store.hasToken))
                if store.download != nil && !installed {
                    Text("One download at a time.").foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            DisclosureGroup("Hugging Face token (only for gated models)") {
                HStack {
                    SecureField(store.hasToken ? "Saved in the Keychain" : "Paste a read token", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        store.saveToken(tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .font(IDEAppearance.Typography.caption)
            if let folder = store.modelsFolder {
                HStack {
                    Text(folder.path).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .controlSize(.small)
                }
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let error = store.storageError {
                Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
    }
}
