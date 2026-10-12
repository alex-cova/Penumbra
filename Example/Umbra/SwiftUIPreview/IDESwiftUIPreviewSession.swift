import AppKit
import CryptoKit
import EditorIntelligence
import Foundation
import Observation
import SwiftIntelligence

/// What a preview session needs from its window. Closures, so the session never holds the
/// workspace and a test supplies plain values.
@MainActor
struct IDESwiftUIPreviewContext {
    /// The file the preview is for, with the text of its live buffer.
    var activeFile: () -> (url: URL, text: String)?
    /// The SwiftPM package and target a file belongs to, nil when it is in none.
    var package: (URL) -> (root: URL, target: String)?
    /// True when the package is trusted, asking the user when it is not.
    var ensureTrusted: () async -> Bool
    var toolchain: () -> IDESwiftUIPreviewToolchain?
    /// Receives the compiler problems of the preview's builds, per file; an empty map clears them.
    var publishDiagnostics: ([URL: [Diagnostic]]) -> Void
    /// The text of an open buffer, so a compiler column lands in what the editor shows.
    var bufferText: (URL) -> String?
}

/// One window's SwiftUI preview: builds the package a file belongs to, links the preview host
/// with it, loads the thunk of the chosen `#Preview` and shows the host's frames.
///
/// The recipe is `SwiftPreviewBuildPlan`'s (pure and tested in SwiftIntelligence); this class
/// runs it and owns the host process. Every run has a generation: a result that a newer run has
/// overtaken is dropped, so typing and saving never show an old frame over a new one. Nothing
/// here runs on the typing path; the caller asks for a refresh after a save or a pause.
@MainActor
@Observable
final class IDESwiftUIPreviewSession {
    enum Phase: Equatable {
        case idle
        case building(String)
        case ready
        case noPreviews
        case unavailable(String)
        case failed(String)

        var isWorking: Bool {
            if case .building = self { return true }
            return false
        }
    }

    enum ColorScheme: String, CaseIterable, Sendable {
        case light, dark
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var blocks: [SwiftPreviewBlock] = []
    private(set) var selectedIndex = 0
    private(set) var frame: NSImage?
    /// The size of `frame` in points.
    private(set) var frameSize = CGSize.zero
    private(set) var fileName: String?
    private(set) var log: [String] = []
    private(set) var colorScheme: ColorScheme = .light
    /// How the frame on the canvas was produced: a build, or the file loaded into the running host.
    private(set) var lastReload: ReloadKind?

    enum ReloadKind: Equatable { case build, hotReload }

    /// Forgets how the last frame was made, so a caller waiting for the next reload can tell it from the last.
    func lastReloadReset() { lastReload = nil }

    // MARK: Collaborators

    @ObservationIgnored private let context: IDESwiftUIPreviewContext
    @ObservationIgnored private let runner: any IDESwiftUIPreviewProcessRunning
    @ObservationIgnored private let cacheRoot: URL

    // MARK: Run state

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderCounter = 0
    @ObservationIgnored private var host: (any IDESwiftUIPreviewHostProcess)?
    @ObservationIgnored private var connection: IDESwiftUIPreviewHostConnection?
    @ObservationIgnored private var viewport = CGSize(width: 360, height: 480)
    @ObservationIgnored private var lastFramePath: String?
    @ObservationIgnored private var currentFixedSize: CGSize?
    @ObservationIgnored private var baseline: Baseline?

    /// What the host process was built from, kept while it runs: what a later save is compared to.
    private struct Baseline {
        var url: URL
        var packageRoot: URL
        var target: String
        var binPath: String
        var modulePaths: [String]
        var toolchain: IDESwiftUIPreviewToolchain
        var stamps: [String: FileStamp]
    }

    private struct FileStamp: Equatable {
        var modified: Date
        var size: Int
    }

    /// Called when a refresh produced or lost a frame; the window uses it to keep its toolbar current.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(
        context: IDESwiftUIPreviewContext,
        runner: any IDESwiftUIPreviewProcessRunning = IDESwiftUIPreviewSubprocessRunner(),
        cacheRoot: URL? = nil
    ) {
        self.context = context
        self.runner = runner
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.umbra.editor/SwiftUIPreviews", isDirectory: true)
    }

    // MARK: Commands

    /// Shows the active file's preview. While the host runs and no other file changed since the
    /// package was built, the file's current text is compiled as a thunk and loaded into it (about
    /// a second); otherwise the package is built again. Starts over when a run is in progress.
    func refresh() {
        start(selecting: nil, allowHotReload: true)
    }

    /// Builds the package again and starts a fresh host, whatever changed.
    func rebuild() {
        start(selecting: nil, allowHotReload: false)
    }

    /// Shows block `index` of the active file.
    func select(_ index: Int) {
        start(selecting: index, allowHotReload: true)
    }

    func setColorScheme(_ scheme: ColorScheme) {
        guard scheme != colorScheme else { return }
        colorScheme = scheme
        scheduleRender()
    }

    /// The size the canvas has, in points. A change re-renders after a short pause.
    func setViewport(_ size: CGSize) {
        guard size.width >= 20, size.height >= 20 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != viewport else { return }
        viewport = rounded
        scheduleRender(after: .milliseconds(120))
    }

    /// A click at a point of the frame, in points.
    func click(at point: CGPoint) {
        guard let connection, phase == .ready else { return }
        renderTask?.cancel()
        renderCounter += 1
        let counter = renderCounter
        let task = Task { [weak self] in
            do {
                _ = try await connection.request(.mouse(type: "down", x: point.x, y: point.y))
                _ = try await connection.request(.mouse(type: "up", x: point.x, y: point.y))
                await self?.render(counter: counter)
            } catch {
                self?.hostEnded()
            }
        }
        renderTask = task
    }

    /// Stops the host and forgets the frame.
    func stop() {
        generation += 1
        pipeline?.cancel()
        pipeline = nil
        renderTask?.cancel()
        renderTask = nil
        endHost()
        frame = nil
        phase = .idle
        context.publishDiagnostics([:])
        onChange?()
    }

    // MARK: Pipeline

    private func start(selecting index: Int?, allowHotReload: Bool) {
        guard let file = context.activeFile() else {
            phase = .unavailable("Open a Swift file to preview it.")
            return
        }
        guard file.url.pathExtension == "swift" else {
            phase = .unavailable("This is not a Swift file.")
            return
        }
        generation += 1
        let token = generation
        pipeline?.cancel()
        renderTask?.cancel()
        fileName = file.url.lastPathComponent
        if let index { selectedIndex = index }
        phase = .building("Reading previews…")
        onChange?()
        let wanted = selectedIndex
        pipeline = Task { [weak self] in
            await self?.run(token: token, url: file.url, text: file.text, wantedIndex: wanted, allowHotReload: allowHotReload)
        }
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation && !Task.isCancelled }

    private func run(token: Int, url: URL, text: String, wantedIndex: Int, allowHotReload: Bool) async {
        // 1. What the file previews.
        let read = await Task.detached(priority: .userInitiated) { () -> ([SwiftPreviewBlock], [String]) in
            guard let parsed = SwiftAnalysis.parse(text) else { return ([], []) }
            let blocks = SwiftPreviewExtractor.extract(from: parsed)
            let imports = parsed.model.imports.map { ($0.isTestable ? "@testable " : "") + "import " + $0.module }
            return (blocks, imports)
        }.value
        guard isCurrent(token) else { return }
        blocks = read.0
        guard !blocks.isEmpty else {
            endHost()
            frame = nil
            phase = .noPreviews
            context.publishDiagnostics([:])
            onChange?()
            return
        }
        selectedIndex = min(max(wantedIndex, 0), blocks.count - 1)
        let block = blocks[selectedIndex]

        // 1b. The host is up and nothing else changed: the file's text goes in as a thunk.
        if allowHotReload {
            let obstacle = await hotReloadObstacle(token: token, url: url)
            guard isCurrent(token) else { return }
            if let obstacle {
                append("Building the package: \(obstacle).\n")
            } else if let baseline,
                      await hotReload(token: token, baseline: baseline, url: url, text: text, imports: read.1, block: block) {
                return
            }
            guard isCurrent(token) else { return }
        }

        // 2. Where it lives, and whether we may build it.
        guard let package = context.package(url) else {
            return fail(token, "This file is not in a SwiftPM target. Previews need a package.")
        }
        guard let toolchain = context.toolchain() else {
            return fail(token, "No swift toolchain was found on PATH.")
        }
        phase = .building("Waiting for trust…")
        guard await context.ensureTrusted() else {
            guard isCurrent(token) else { return }
            return fail(token, "Building a preview runs the package's code. Trust the folder to continue.")
        }
        guard isCurrent(token) else { return }

        // 3. The recipe.
        let directory = workDirectory(for: package.root)
        let plan = makePlan(
            root: package.root, directory: directory, target: package.target, url: url, text: text,
            imports: read.1, block: block
        )
        let fileManager = FileManager.default
        do {
            for sub in ["host", "thunks", "frames"] {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: plan.job.workDirectory).appendingPathComponent(sub), withIntermediateDirectories: true
                )
            }
        } catch {
            return fail(token, "Could not create \(plan.job.workDirectory): \(error.localizedDescription)")
        }
        currentFixedSize = plan.fixedSize.map { CGSize(width: $0.width, height: $0.height) }

        // 4. Build the package's target.
        phase = .building("Building \(package.target)…")
        let root = URL(fileURLWithPath: package.root.path)
        let build = await execute(plan.buildCommand, toolchain: toolchain, directory: root)
        guard isCurrent(token) else { return }
        publish(build.output, root: package.root)
        guard build.succeeded else {
            return fail(token, Self.summary(of: build.output, fallback: "swift build failed."))
        }
        let binPathResult = await execute(plan.binPathCommand, toolchain: toolchain, directory: root, echo: false)
        guard isCurrent(token) else { return }
        guard binPathResult.succeeded,
              let binPath = binPathResult.output.split(whereSeparator: \.isNewline).last.map(String.init), binPath.hasPrefix("/")
        else { return fail(token, "swift could not report where it built.") }
        let located = IDESwiftUIPreviewArtifacts.locate(binPath: binPath, module: plan.moduleName)
        guard !located.objects.isEmpty else {
            return fail(token, "The build left no object files for \(package.target).")
        }
        // The object of the file with `@main` defines `main`, which the host has itself.
        var objects = located.objects
        let symbols = await execute(plan.definedSymbolsCommand(objects: objects), toolchain: toolchain, directory: root, echo: false)
        guard isCurrent(token) else { return }
        if symbols.succeeded {
            let withMain = IDESwiftUIPreviewArtifacts.objectsDefiningMain(nmOutput: symbols.output, files: objects)
            if !withMain.isEmpty {
                objects.removeAll { withMain.contains($0) }
                append("Not linking \(withMain.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", ")): it defines main.\n")
            }
        }
        modulePaths = located.modulePaths

        // 5. The shared support module (once), the host linked with the objects, and the thunk.
        phase = .building("Linking the preview…")
        if !fileManager.fileExists(atPath: plan.supportLibraryPath) {
            do {
                try fileManager.createDirectory(atPath: plan.supportDirectory, withIntermediateDirectories: true)
                try SwiftPreviewSupportSource.text.write(toFile: plan.supportSourcePath, atomically: true, encoding: .utf8)
            } catch {
                return fail(token, "Could not write the preview support module: \(error.localizedDescription)")
            }
            let support = await execute(plan.supportCommand, toolchain: toolchain, directory: root)
            guard isCurrent(token) else { return }
            guard support.succeeded else {
                try? fileManager.removeItem(atPath: plan.supportDirectory)
                return fail(token, Self.summary(of: support.output, fallback: "Compiling the preview support module failed."))
            }
        }
        do {
            try plan.hostSource.write(toFile: plan.hostSourcePath, atomically: true, encoding: .utf8)
        } catch {
            return fail(token, "Could not write the preview sources: \(error.localizedDescription)")
        }
        let link = await execute(plan.hostCommand(binPath: binPath, objects: objects, modulePaths: modulePaths), toolchain: toolchain, directory: root)
        guard isCurrent(token) else { return }
        guard link.succeeded else { return fail(token, Self.summary(of: link.output, fallback: "Linking the preview failed.")) }
        phase = .building("Compiling the preview…")
        let thunk = await compileThunk(
            plan: plan, token: token, binPath: binPath, modulePaths: modulePaths, toolchain: toolchain,
            directory: root, modes: [.copy, .imported]
        )
        guard isCurrent(token) else { return }
        guard thunk.succeeded else {
            publish(thunk.output, root: package.root)
            return fail(token, Self.summary(of: thunk.output, fallback: "Compiling the preview failed."))
        }
        publish("", root: package.root)

        // 6. A fresh host for the new objects, and the first frame.
        phase = .building("Starting the preview…")
        endHost()
        let socket = Self.socketPath(for: directory, generation: token)
        socketPath = socket
        do {
            let process = try runner.startHost(
                executable: binPath + "/UmbraPreviewHost", arguments: ["--socket", socket],
                workingDirectory: URL(fileURLWithPath: binPath),
                onOutput: { [weak self] text in
                    Task { @MainActor [weak self] in self?.append(text) }
                }
            )
            host = process
            let connection = try await IDESwiftUIPreviewHostConnection.connect(path: socket)
            guard isCurrent(token) else {
                connection.close()
                process.terminate()
                if host === process { host = nil }
                return
            }
            self.connection = connection
            let ready = try await connection.nextEvent()
            guard ready.name == "ready" else { return fail(token, "The preview host did not start.") }
            let loaded = try await connection.request(
                .load(dylib: plan.thunkLibraryPath(generation: token), generation: token)
            )
            guard isCurrent(token) else { return }
            guard loaded.isOK else {
                return fail(token, "The preview could not be loaded: \(loaded.error ?? "unknown error")")
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(token) else { return }
            append("Host connection failed: \(error)\n")
            return fail(token, "The preview host stopped unexpectedly (\(error)).")
        }
        framePrefix = plan.framePath(generation: token)
        lastReload = .build
        let stamps = await Task.detached(priority: .userInitiated) { [root = package.root] in
            Self.stamps(under: root, excluding: url)
        }.value
        baseline = Baseline(
            url: url, packageRoot: package.root, target: package.target, binPath: binPath,
            modulePaths: modulePaths, toolchain: toolchain, stamps: stamps
        )
        phase = .ready
        await render(counter: nextRenderCounter())
        onChange?()
    }

    @ObservationIgnored private var framePrefix = ""
    @ObservationIgnored private var modulePaths: [String] = []

    private func nextRenderCounter() -> Int {
        renderCounter += 1
        return renderCounter
    }

    private func makePlan(
        root: URL, directory: URL, target: String, url: URL, text: String, imports: [String], block: SwiftPreviewBlock
    ) -> SwiftPreviewBuildPlan {
        SwiftPreviewBuildPlan(job: .init(
            packageRoot: root.path,
            scratchPath: directory.appendingPathComponent("scratch").path,
            workDirectory: directory.appendingPathComponent("work").path,
            targetName: target, sourcePath: url.path, sourceText: text,
            imports: imports, block: block, deploymentTarget: Self.deploymentTarget
        ))
    }

    /// Writes and compiles the thunk, trying each mode in turn. The result is the first that
    /// compiled, or the last one's output.
    private func compileThunk(
        plan: SwiftPreviewBuildPlan, token: Int, binPath: String, modulePaths: [String],
        toolchain: IDESwiftUIPreviewToolchain, directory: URL, modes: [SwiftPreviewBuildPlan.ThunkMode]
    ) async -> IDESwiftUIPreviewRunResult {
        var last = IDESwiftUIPreviewRunResult(status: 1, output: "", cancelled: false)
        for (index, mode) in modes.enumerated() {
            do {
                try plan.thunkSource(generation: token, mode: mode)
                    .write(toFile: plan.thunkSourcePath(generation: token), atomically: true, encoding: .utf8)
            } catch {
                return IDESwiftUIPreviewRunResult(status: 1, output: "Could not write the thunk: \(error)", cancelled: false)
            }
            last = await execute(
                plan.thunkCommand(binPath: binPath, generation: token, modulePaths: modulePaths), toolchain: toolchain, directory: directory,
                echo: index == modes.count - 1
            )
            if last.succeeded || last.cancelled { return last }
            if index + 1 < modes.count {
                append("The file could not be compiled as a copy; showing the types the package was built with.\n")
            }
        }
        return last
    }

    // MARK: Reloading into the running host

    /// Why the file cannot just be loaded into the running host; nil when it can.
    private func hotReloadObstacle(token: Int, url: URL) async -> String? {
        guard let baseline else { return "nothing has been built yet" }
        guard connection != nil, host != nil else { return "the preview host is not running" }
        guard baseline.url == url else { return "another file is being previewed" }
        let root = baseline.packageRoot
        let stamps = await Task.detached(priority: .userInitiated) { Self.stamps(under: root, excluding: url) }.value
        guard isCurrent(token) else { return "superseded" }
        if stamps != baseline.stamps {
            let changed = Set(stamps.keys).symmetricDifference(baseline.stamps.keys).union(
                stamps.filter { baseline.stamps[$0.key] != $0.value }.keys
            )
            let names = changed.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return "another file changed (\(names))"
        }
        return nil
    }

    /// Compiles the file's current text as a thunk and loads it into the running host. Returns
    /// false when that did not work, so the caller builds instead.
    private func hotReload(
        token: Int, baseline: Baseline, url: URL, text: String, imports: [String], block: SwiftPreviewBlock
    ) async -> Bool {
        guard let connection else { return false }
        let directory = workDirectory(for: baseline.packageRoot)
        let plan = makePlan(
            root: baseline.packageRoot, directory: directory, target: baseline.target, url: url, text: text,
            imports: imports, block: block
        )
        phase = .building("Reloading…")
        onChange?()
        // Only the copy shows the edit; the imported thunk would show what was built.
        let compile = await compileThunk(
            plan: plan, token: token, binPath: baseline.binPath, modulePaths: baseline.modulePaths,
            toolchain: baseline.toolchain, directory: baseline.packageRoot, modes: [.copy]
        )
        guard isCurrent(token) else { return true }
        guard compile.succeeded else {
            publish(compile.output, root: baseline.packageRoot)
            append("The file could not be loaded into the running preview; building the package instead.\n")
            return false
        }
        do {
            let loaded = try await connection.request(
                .load(dylib: plan.thunkLibraryPath(generation: token), generation: token)
            )
            guard isCurrent(token) else { return true }
            guard loaded.isOK else {
                append("Loading the file failed: \(loaded.error ?? "the host refused it"); building the package instead.\n")
                return false
            }
        } catch {
            append("Loading the file failed: the host stopped; building the package instead.\n")
            return false
        }
        publish("", root: baseline.packageRoot)
        currentFixedSize = plan.fixedSize.map { CGSize(width: $0.width, height: $0.height) }
        framePrefix = plan.framePath(generation: token)
        lastReload = .hotReload
        phase = .ready
        await render(counter: nextRenderCounter())
        onChange?()
        return true
    }

    /// Modification time and size of every Swift file under `root` except `excluded`: what tells the
    /// session that the code the host was linked with is still what is on disk.
    nonisolated private static func stamps(under root: URL, excluding excluded: URL) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let fileManager = FileManager.default
        let skipped: Set<String> = [".build", ".git", ".swiftpm", "node_modules", "DerivedData"]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return result }
        let excludedPath = excluded.standardizedFileURL.path
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipped.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift", url.standardizedFileURL.path != excludedPath,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate else { continue }
            result[url.path] = FileStamp(modified: modified, size: values.fileSize ?? 0)
        }
        return result
    }

    // MARK: Frames

    private func scheduleRender(after delay: Duration = .zero) {
        guard connection != nil, phase == .ready else { return }
        renderTask?.cancel()
        let counter = nextRenderCounter()
        renderTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.render(counter: counter)
        }
    }

    private func render(counter: Int) async {
        guard let connection, counter == renderCounter else { return }
        let size = currentFixedSize ?? viewport
        let path = framePrefix.replacingOccurrences(of: ".png", with: "-\(counter).png")
        do {
            let reply = try await connection.request(.render(
                generation: generation, width: size.width, height: size.height,
                scale: Double(NSScreen.main?.backingScaleFactor ?? 2), scheme: colorScheme.rawValue, output: path
            ))
            // A newer render or a new run took over while this one was drawing.
            guard counter == renderCounter, self.connection === connection else { return }
            guard reply.isOK, let image = NSImage(contentsOfFile: path) else {
                append("Render failed: \(reply.error ?? "no frame")\n")
                return
            }
            if let previous = lastFramePath { try? FileManager.default.removeItem(atPath: previous) }
            lastFramePath = path
            frameSize = CGSize(width: size.width, height: size.height)
            image.size = NSSize(width: size.width, height: size.height)
            frame = image
            onChange?()
        } catch {
            hostEnded()
        }
    }

    // MARK: Helpers

    private func execute(
        _ command: SwiftPreviewCommand, toolchain: IDESwiftUIPreviewToolchain, directory: URL, echo: Bool = true
    ) async -> IDESwiftUIPreviewRunResult {
        if echo { append("$ \(command.tool == .swift ? "swift" : "swiftc") \(command.arguments.prefix(3).joined(separator: " ")) …\n") }
        return await runner.run(
            executable: toolchain.executable(for: command.tool), arguments: command.arguments, workingDirectory: directory,
            onOutput: { [weak self] text in
                guard echo else { return }
                Task { @MainActor [weak self] in self?.append(text) }
            }
        )
    }

    private func append(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) { log.append(String(line)) }
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func publish(_ output: String, root: URL) {
        let messages = SwiftBuildOutputParser.parse(output)
        let lookup = context.bufferText
        let diagnostics = SwiftBuildOutputParser.diagnostics(from: messages, baseDirectory: root) { url in
            lookup(url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        context.publishDiagnostics(diagnostics)
    }

    private func fail(_ token: Int, _ message: String) {
        guard token == generation else { return }
        phase = .failed(message)
        onChange?()
    }

    private func endHost() {
        baseline = nil
        connection?.close()
        connection = nil
        host?.terminate()
        host = nil
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
            self.socketPath = nil
        }
    }

    @ObservationIgnored private var socketPath: String?

    private func hostEnded() {
        guard connection != nil else { return }
        endHost()
        if phase == .ready { phase = .failed("The preview host stopped. Refresh to start it again.") }
        onChange?()
    }

    private func workDirectory(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// A short path: a socket's `sun_path` holds about a hundred bytes. Each run has its own, so a
    /// new host never meets the one it replaces, which may not have exited yet.
    private static func socketPath(for directory: URL, generation: Int) -> String {
        let digest = SHA256.hash(data: Data(directory.path.utf8))
        let name = digest.prefix(5).map { String(format: "%02x", $0) }.joined()
        return NSTemporaryDirectory() + "umbra-pv-\(name)-\(generation).sock"
    }

    /// The macOS major version, `15.0`: thunks are compiled for the machine they run on.
    private static var deploymentTarget: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).0"
    }

    /// The first error lines, else a fallback: what the panel shows above the Problems entries.
    static func summary(of output: String, fallback: String) -> String {
        let errors = output.split(whereSeparator: \.isNewline).filter { $0.contains(": error: ") }
        guard !errors.isEmpty else { return fallback }
        return errors.prefix(3).map { line -> String in
            let text = String(line)
            if let range = text.range(of: ": error: ") {
                let file = (String(text[..<range.lowerBound]) as NSString).lastPathComponent
                return "\(file): \(text[range.upperBound...])"
            }
            return text
        }.joined(separator: "\n")
    }
}
