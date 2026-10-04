import AgentKitMLX
import Foundation
import LocalModelStore
import Observation

/// On-device models for the agent: what is installed, searching Hugging Face, one download at a
/// time (pausable, resumable after a relaunch), and which model is loaded in memory. The network is
/// used only to search and download, and only when the user asks; running a model needs none.
@MainActor
@Observable
final class IDELocalModelsStore {
    static let shared = IDELocalModelsStore()

    /// What the details pane shows once a result is selected. `nil` fields are still loading or unknown.
    struct Detail: Equatable {
        var sizeBytes: Int64?
        /// The chat template takes tools, so the agent can use the model. `nil`: could not tell.
        var supportsTools: Bool?
        var isGated = false
        var error: String?
    }

    struct Download: Equatable {
        var id: String
        var progress: LocalModelDownloadProgress
        var isPaused: Bool
    }

    private(set) var installed: [InstalledLocalModel] = []
    private(set) var storageError: String?

    var query = ""
    private(set) var results: [HFModelSummary] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var details: [String: Detail] = [:]

    private(set) var download: Download?
    private(set) var downloadError: String?

    private(set) var loadedID: String?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var memoryBytes = 0

    private(set) var hasToken = false

    @ObservationIgnored private let paths: LocalModelPaths?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let runtime: LocalModelRuntime
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadControl: LocalModelDownloadControl?
    @ObservationIgnored private var pausedStaging: URL?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var isPrepared = false

    /// `rootURL` pins the models folder (tests); otherwise it is `Application Support/com.umbra.editor/Models`.
    init(rootURL: URL? = nil, session: URLSession = .shared, runtime: LocalModelRuntime = .shared) {
        paths = rootURL.map(LocalModelPaths.init(root:)) ?? (try? LocalModelPaths.defaultRoot(folderName: "com.umbra.editor")).map(LocalModelPaths.init(root:))
        self.session = session
        self.runtime = runtime
        if paths == nil { storageError = "The models folder could not be created." }
    }

    var availability: MLXAvailabilityStatus { MLXAvailability.currentStatus() }
    var modelsFolder: URL? { paths?.root }

    /// Deferred to first use: touching the disk is not launch work.
    func prepareIfNeeded() {
        guard !isPrepared, let paths else { return }
        isPrepared = true
        do { try paths.createDirectories() } catch { storageError = error.localizedDescription }
        let catalog = LocalModelCatalog(paths: paths)
        catalog.clearStaging()
        if let paused = catalog.pausedDownload() {
            pausedStaging = paused.staging
            download = Download(id: paused.checkpoint.repositoryID, progress: paused.checkpoint.progress, isPaused: true)
        }
        hasToken = ((try? LocalModelTokenStore.load()) ?? nil) != nil
        refreshInstalled()
    }

    func refreshInstalled() {
        guard let paths else { return }
        installed = LocalModelCatalog(paths: paths).installed()
    }

    // MARK: - Token

    func saveToken(_ token: String) {
        do {
            try LocalModelTokenStore.save(token)
            hasToken = ((try? LocalModelTokenStore.load()) ?? nil) != nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    // MARK: - Search

    func search() async {
        prepareIfNeeded()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchError = nil
        do {
            let found = try await HuggingFaceSearchEngine.search(query: query, session: session)
            guard generation == searchGeneration else { return }
            results = found
        } catch {
            guard generation == searchGeneration else { return }
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    /// Size and tool support, fetched when a result is selected, so a search itself stays one request.
    func loadDetails(for id: String) async {
        if let known = details[id], known.error == nil, known.sizeBytes != nil { return }
        let token = (try? LocalModelTokenStore.load()) ?? nil
        var detail = Detail()
        do {
            let info = try await HuggingFaceSearchEngine.repositoryInfo(id: id, token: token, session: session)
            detail.sizeBytes = LocalModelDownloader.select(info.siblings).reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            detail.isGated = info.isGated
        } catch {
            detail.error = error.localizedDescription
        }
        if let template = await ChatTemplate.fetch(id: id, token: token, session: session) {
            detail.supportsTools = ChatTemplate.supportsTools(template)
        }
        details[id] = detail
    }

    // MARK: - Download

    var canStartDownload: Bool { download == nil && paths != nil }

    func startDownload(_ id: String) {
        prepareIfNeeded()
        guard canStartDownload, let paths else { return }
        downloadError = nil
        run(id: id, paths: paths, checkpoint: nil, staging: nil)
    }

    func resumeDownload() {
        guard let paths, let paused = LocalModelCatalog(paths: paths).pausedDownload(), download?.isPaused == true else { return }
        downloadError = nil
        run(id: paused.checkpoint.repositoryID, paths: paths, checkpoint: paused.checkpoint, staging: paused.staging)
    }

    func pauseDownload() {
        guard let control = downloadControl, download?.isPaused == false else { return }
        Task { await control.pause() }
    }

    func cancelDownload() {
        downloadControl?.cancel()
        if download?.isPaused == true, let staging = pausedStaging, let paths {
            LocalModelCatalog(paths: paths).discardPausedDownload(staging: staging)
            pausedStaging = nil
            download = nil
        }
    }

    private func run(id: String, paths: LocalModelPaths, checkpoint: LocalModelDownloadCheckpoint?, staging: URL?) {
        let control = LocalModelDownloadControl()
        downloadControl = control
        download = Download(id: id, progress: LocalModelDownloadProgress(bytesDownloaded: checkpoint?.completedBytes ?? 0, totalBytes: checkpoint?.totalBytes ?? 0), isPaused: false)
        let token = (try? LocalModelTokenStore.load()) ?? nil
        let downloader = LocalModelDownloader(session: LocalModelDownloader.makeSession())
        let report: @Sendable (LocalModelDownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress, to: id) }
        }
        downloadTask = Task { [weak self] in
            do {
                _ = try await downloader.download(
                    id: id, token: token, into: paths, control: control, checkpoint: checkpoint, staging: staging,
                    progress: report)
                self?.finishDownload(error: nil, paused: false)
            } catch is LocalModelDownloadPaused {
                self?.finishDownload(error: nil, paused: true)
            } catch is CancellationError {
                self?.finishDownload(error: nil, paused: false)
            } catch {
                self?.finishDownload(error: error.localizedDescription, paused: false)
            }
        }
    }

    private func apply(_ progress: LocalModelDownloadProgress, to id: String) {
        guard download?.id == id, download?.isPaused == false else { return }
        download?.progress = progress
    }

    private func finishDownload(error: String?, paused: Bool) {
        downloadTask = nil
        downloadControl = nil
        if paused, let paths, let state = LocalModelCatalog(paths: paths).pausedDownload() {
            pausedStaging = state.staging
            download = Download(id: state.checkpoint.repositoryID, progress: state.checkpoint.progress, isPaused: true)
        } else {
            download = nil
            pausedStaging = nil
        }
        downloadError = error
        refreshInstalled()
    }

    // MARK: - Installed models

    func delete(_ model: InstalledLocalModel) {
        guard let paths else { return }
        if loadedID == model.id { unload() }
        do {
            try LocalModelCatalog(paths: paths).delete(model)
        } catch {
            downloadError = error.localizedDescription
        }
        refreshInstalled()
    }

    /// What the model's own files say: its chat template, and the context it was trained for.
    func info(for model: InstalledLocalModel) -> MLXModelInfo { MLXModelInspector.inspect(directory: model.directory) }

    // MARK: - Memory

    func load(_ model: InstalledLocalModel) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            _ = try await runtime.load(model)
            loadedID = model.id
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
        await refreshMemory()
    }

    func unload() {
        Task {
            await runtime.unload()
            loadedID = nil
            await refreshMemory()
        }
    }

    func refreshMemory() async {
        memoryBytes = await runtime.memoryBytes()
        loadedID = await runtime.loaded?.model.id
    }
}
