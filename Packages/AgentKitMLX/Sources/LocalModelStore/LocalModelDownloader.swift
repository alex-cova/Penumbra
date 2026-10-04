import Foundation

/// Downloads an MLX model repository from Hugging Face into a folder Hextech controls.
///
/// Files land in a staging folder on the destination volume, a manifest is written last, and the
/// folder is renamed into place. Anything that fails or is cancelled leaves nothing behind that
/// could be mistaken for a working model. A paused download keeps its staging folder and checkpoint
/// so it can resume later.
public final class LocalModelDownloader: Sendable {
    /// Only what MLX needs to load an LLM: weights, tokenizer, configs and chat templates.
    public static let allowedExtensions: Set<String> = ["safetensors", "json", "jsonl", "jinja", "txt", "model", "tiktoken"]

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = LocalModelDownloader.makeSession(), endpoint: URL = HuggingFaceSearchEngine.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        return URLSession(configuration: config)
    }

    public static func select(_ siblings: [HFSibling]) -> [HFSibling] {
        siblings.filter { allowedExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
    }

    /// Cancelling always surfaces as `CancellationError`. Pausing surfaces as `LocalModelDownloadPaused`
    /// after writing a checkpoint.
    public func download(
        id: String,
        token: String? = nil,
        into paths: LocalModelPaths,
        control: LocalModelDownloadControl? = nil,
        checkpoint: LocalModelDownloadCheckpoint? = nil,
        staging: URL? = nil,
        progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) async throws -> InstalledLocalModel {
        do {
            return try await install(
                id: id, token: token, into: paths, control: control,
                checkpoint: checkpoint, staging: staging, progress: progress
            )
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    public func discardCheckpoint(at staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    private func install(
        id: String,
        token: String?,
        into paths: LocalModelPaths,
        control: LocalModelDownloadControl?,
        checkpoint: LocalModelDownloadCheckpoint?,
        staging: URL?,
        progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) async throws -> InstalledLocalModel {
        let files: [HFSibling]
        let revision: String
        let stagingDirectory: URL
        let meter: LocalModelTransferMeter
        var completedFiles: [String]
        var resumeData: Data?

        if let checkpoint {
            guard checkpoint.repositoryID == id else { throw LocalModelError.invalidRepositoryID(id) }
            let info = try await HuggingFaceSearchEngine.repositoryInfo(id: id, token: token, endpoint: endpoint, session: session)
            files = Self.select(info.siblings)
            guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw LocalModelError.noModelFiles(id) }
            revision = checkpoint.revision
            stagingDirectory = try stagingURL(for: checkpoint, paths: paths, provided: staging)
            meter = LocalModelTransferMeter(totalBytes: checkpoint.totalBytes)
            meter.restore(completedBytes: checkpoint.completedBytes, currentFile: checkpoint.currentFile)
            completedFiles = checkpoint.completedFiles
            resumeData = checkpoint.resumeData
        } else {
            let info = try await HuggingFaceSearchEngine.repositoryInfo(id: id, token: token, endpoint: endpoint, session: session)
            files = Self.select(info.siblings)
            guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw LocalModelError.noModelFiles(id) }

            let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            try paths.createDirectories()
            try Self.requireFreeSpace(total, at: paths.root)

            stagingDirectory = staging ?? paths.newStagingDirectory()
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            revision = info.sha ?? "main"
            meter = LocalModelTransferMeter(totalBytes: total)
            completedFiles = []
            resumeData = nil
        }

        var installed = false
        var keptForPause = false
        defer {
            if !installed && !keptForPause {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let transfer = LocalModelFileTransfer(session: session, meter: meter, progress: progress, control: control)

        for file in files {
            try control?.throwIfCancelled()
            if try pauseIfRequested(
                control: control, id: id, revision: revision, staging: stagingDirectory,
                completedFiles: completedFiles, meter: meter, progress: progress
            ) {
                keptForPause = true
                throw LocalModelDownloadPaused()
            }

            guard !completedFiles.contains(file.path) else { continue }

            meter.begin(file: file.path)
            let resumeForFile = resumeData
            resumeData = nil

            do {
                try await fetch(
                    file, id: id, revision: revision, token: token, into: stagingDirectory,
                    resumeData: resumeForFile, transfer: transfer, meter: meter
                )
            } catch let error as URLError where error.code == .cancelled {
                if control?.isPauseRequested == true {
                    try saveCheckpoint(
                        id: id, revision: revision, staging: stagingDirectory,
                        completedFiles: completedFiles, meter: meter, currentFile: file.path,
                        resumeData: control?.takeResumeData(), progress: progress
                    )
                    keptForPause = true
                    throw LocalModelDownloadPaused()
                }
                throw CancellationError()
            } catch is CancellationError {
                if control?.isPauseRequested == true {
                    try saveCheckpoint(
                        id: id, revision: revision, staging: stagingDirectory,
                        completedFiles: completedFiles, meter: meter, currentFile: file.path,
                        resumeData: control?.takeResumeData(), progress: progress
                    )
                    keptForPause = true
                    throw LocalModelDownloadPaused()
                }
                throw CancellationError()
            }

            completedFiles.append(file.path)
            try control?.throwIfCancelled()
        }

        let total = meter.final().totalBytes
        let manifest = LocalModelManifest(repositoryID: id, revision: revision, downloadedAt: .now, totalBytes: total)
        try LocalModelCatalog.writeManifest(manifest, into: stagingDirectory)
        try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(LocalModelDownloadCheckpoint.fileName))

        let destination = try paths.directory(for: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagingDirectory)
        } else {
            try FileManager.default.moveItem(at: stagingDirectory, to: destination)
        }
        installed = true

        progress(meter.final())
        return InstalledLocalModel(manifest: manifest, directory: destination)
    }

    private func fetch(
        _ file: HFSibling, id: String, revision: String, token: String?, into staging: URL,
        resumeData: Data?, transfer: LocalModelFileTransfer, meter: LocalModelTransferMeter
    ) async throws {
        let destination = try LocalModelPaths.safeDestination(for: file.path, under: staging)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var request = URLRequest(url: Self.resolveURL(endpoint: endpoint, id: id, revision: revision, path: file.path))
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (temp, response) = try await transfer.download(request: request, resumeData: resumeData)
        defer { try? fileManager.removeItem(at: temp) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelError.downloadFailed(file: file.path, status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let actual = (try? fileManager.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
        if let expected = file.size, actual != expected {
            throw LocalModelError.incompleteDownload(file: file.path, expected: expected, actual: actual)
        }
        try Self.installDownloadedFile(from: temp, to: destination)
        meter.completeFile(size: actual)
    }

    /// Moves a finished download into staging, copying when a cross-volume move is required.
    private static func installDownloadedFile(from temp: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: temp, to: destination)
        } catch {
            try fileManager.copyItem(at: temp, to: destination)
        }
    }

    private func pauseIfRequested(
        control: LocalModelDownloadControl?, id: String, revision: String, staging: URL,
        completedFiles: [String], meter: LocalModelTransferMeter,
        progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) throws -> Bool {
        guard control?.isPauseRequested == true else { return false }
        try saveCheckpoint(
            id: id, revision: revision, staging: staging,
            completedFiles: completedFiles, meter: meter, currentFile: meter.final().currentFile,
            resumeData: control?.takeResumeData(), progress: progress
        )
        return true
    }

    private func saveCheckpoint(
        id: String, revision: String, staging: URL, completedFiles: [String],
        meter: LocalModelTransferMeter, currentFile: String?, resumeData: Data?,
        progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) throws {
        let snapshot = meter.final()
        let checkpoint = LocalModelDownloadCheckpoint(
            repositoryID: id,
            revision: revision,
            totalBytes: snapshot.totalBytes,
            completedBytes: snapshot.bytesDownloaded,
            completedFiles: completedFiles,
            currentFile: currentFile,
            resumeData: resumeData,
            pausedAt: .now
        )
        try checkpoint.write(into: staging)
        var paused = snapshot
        paused.isPaused = true
        paused.bytesPerSecond = nil
        progress(paused)
    }

    private func stagingURL(for checkpoint: LocalModelDownloadCheckpoint, paths: LocalModelPaths, provided: URL?) throws -> URL {
        if let provided { return provided }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.stagingRoot, includingPropertiesForKeys: nil
        ) else { throw LocalModelError.notInstalled(checkpoint.repositoryID) }
        for entry in entries {
            if LocalModelDownloadCheckpoint.read(from: entry)?.repositoryID == checkpoint.repositoryID {
                return entry
            }
        }
        throw LocalModelError.notInstalled(checkpoint.repositoryID)
    }

    public static func resolveURL(endpoint: URL, id: String, revision: String, path: String) -> URL {
        var url = endpoint.appendingPathComponent(id).appendingPathComponent("resolve").appendingPathComponent(revision)
        for component in path.split(separator: "/") { url = url.appendingPathComponent(String(component)) }
        return url
    }

    private static func requireFreeSpace(_ required: Int64, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < required {
            throw LocalModelError.insufficientDiskSpace(required: required, available: available)
        }
    }
}

/// One install operation: owns a URLSession delegate for every file in the transfer.
private final class LocalModelFileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let meter: LocalModelTransferMeter
    private let progress: @Sendable (LocalModelDownloadProgress) -> Void
    private let control: LocalModelDownloadControl?
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private var finishedTaskIDs: Set<Int> = []

    init(
        session: URLSession, meter: LocalModelTransferMeter,
        progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void,
        control: LocalModelDownloadControl?
    ) {
        self.meter = meter
        self.progress = progress
        self.control = control
        let config = session.configuration
        super.init()
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func download(request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse) {
        try control?.throwIfCancelled()
        return try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: request)
            }
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            lock.unlock()
            control?.registerTask(task)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if let snapshot = meter.add(bytesWritten) { progress(snapshot) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        control?.clearTask()
        // URLSession deletes `location` as soon as this delegate method returns; take a copy now.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).model-download")
        do {
            guard FileManager.default.fileExists(atPath: location.path) else {
                throw LocalModelError.downloadFailed(file: downloadTask.originalRequest?.url?.lastPathComponent ?? "file", status: -1)
            }
            if FileManager.default.fileExists(atPath: owned.path) {
                try FileManager.default.removeItem(at: owned)
            }
            try FileManager.default.copyItem(at: location, to: owned)
            lock.lock()
            finishedTaskIDs.insert(downloadTask.taskIdentifier)
            lock.unlock()
            resume(task: downloadTask, result: .success((owned, downloadTask.response ?? URLResponse())))
        } catch {
            resume(task: downloadTask, result: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        control?.clearTask()
        guard let error else { return }
        lock.lock()
        let alreadyFinished = finishedTaskIDs.remove(task.taskIdentifier) != nil
        lock.unlock()
        guard !alreadyFinished else { return }
        resume(task: task, result: .failure(error))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        let originalHost = task.originalRequest?.url?.host()
        if redirected.url?.host() != originalHost { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(redirected)
    }

    private func resume(task: URLSessionTask, result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        continuation?.resume(with: result)
    }
}
