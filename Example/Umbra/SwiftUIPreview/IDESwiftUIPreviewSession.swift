import AppKit
import CryptoKit
import EditorIntelligence
import Foundation
import Observation
import SwiftIntelligence

/// The build a file belongs to: where it is run from, which target, and by what.
struct IDESwiftUIPreviewPackage: Equatable {
    /// The directory of `Package.swift`, or the one that holds the `.xcodeproj`.
    var root: URL
    var target: String
    var buildSystem: SwiftPreviewBuildPlan.BuildSystem = .swiftPM
}

/// What a preview session needs from its window. Closures, so the session never holds the
/// workspace and a test supplies plain values.
@MainActor
struct IDESwiftUIPreviewContext {
    /// The file the preview is for, with the text of its live buffer.
    var activeFile: () -> (url: URL, text: String)?
    /// The SwiftPM package or Xcode project and target a file belongs to, nil when it is in none.
    var package: (URL) -> IDESwiftUIPreviewPackage?
    /// True when the package or project is trusted, asking the user when it is not.
    var ensureTrusted: (IDESwiftUIPreviewPackage) async -> Bool
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

    /// `DynamicTypeSize`'s cases, by name (what the host's environment reads).
    enum TextSize: String, CaseIterable, Sendable {
        case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
        case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

        var title: String {
            switch self {
            case .xSmall: return "Extra Small"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large (default)"
            case .xLarge: return "Extra Large"
            case .xxLarge: return "Extra Extra Large"
            case .xxxLarge: return "Extra Extra Extra Large"
            case .accessibility1: return "Accessibility 1"
            case .accessibility2: return "Accessibility 2"
            case .accessibility3: return "Accessibility 3"
            case .accessibility4: return "Accessibility 4"
            case .accessibility5: return "Accessibility 5"
            }
        }
    }

    /// A language the preview can be shown in; `identifier` is empty for the system's.
    struct Language: Hashable, Sendable, Identifiable {
        var identifier: String
        var title: String
        var id: String { identifier }
        var isRightToLeft: Bool { ["ar", "he", "fa", "ur"].contains(String(identifier.prefix(2))) }

        static let system = Language(identifier: "", title: "System")
        static let all: [Language] = [
            .system,
            Language(identifier: "en", title: "English"), Language(identifier: "es", title: "Spanish"),
            Language(identifier: "fr", title: "French"), Language(identifier: "de", title: "German"),
            Language(identifier: "ja", title: "Japanese"), Language(identifier: "zh-Hans", title: "Chinese (Simplified)"),
            Language(identifier: "ar", title: "Arabic"), Language(identifier: "he", title: "Hebrew")
        ]
    }

    /// How big the preview's window is: the canvas (it fills the panel), the view's own ideal size,
    /// a phone's screen, or a fixed size.
    enum SizePreset: Hashable, Sendable, Identifiable {
        case canvas
        /// The size the view asks for (`.frame(width:height:)` and the like); the canvas when it asks for none.
        case content
        case device(IDESwiftUIPreviewDevice)
        case fixed(width: Int, height: Int)

        var id: String {
            switch self {
            case .canvas: return "canvas"
            case .content: return "content"
            case .device(let device): return "device-\(device.id)"
            case .fixed(let width, let height): return "\(width)x\(height)"
            }
        }

        var title: String {
            switch self {
            case .canvas: return "Fit the Canvas"
            case .content: return "Content Size"
            case .device(let device): return device.name
            case .fixed(let width, let height): return "\(width) × \(height)"
            }
        }

        var device: IDESwiftUIPreviewDevice? {
            if case .device(let device) = self { return device }
            return nil
        }

        static let layouts: [SizePreset] = [.canvas, .content]
        static let devices: [SizePreset] = IDESwiftUIPreviewDevice.all.map { .device($0) }
        static let windows: [SizePreset] = [
            .fixed(width: 320, height: 240), .fixed(width: 480, height: 360),
            .fixed(width: 640, height: 480), .fixed(width: 800, height: 600), .fixed(width: 1024, height: 768)
        ]
        static let all: [SizePreset] = layouts + devices + windows
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
    private(set) var textSize: TextSize = .large
    private(set) var language: Language = .system
    private(set) var isRightToLeft = false
    private(set) var sizePreset: SizePreset = .canvas
    /// How much the frame is magnified on the canvas.
    private(set) var zoom: IDESwiftUIPreviewZoom = .fit
    /// Whether a device's bezel is drawn around the frame.
    private(set) var showsDeviceFrame = true
    /// Keep the preview's own trailing `.frame(width:height:)` in a device or window size. Off by
    /// default: the size that was chosen is the point of choosing it.
    private(set) var keepsPreviewFrame = false
    /// The fixed frame the current thunk leaves out, as written; nil when it left none out.
    private(set) var ignoredFrame: String?
    /// How the frame on the canvas was produced: a build, or the file loaded into the running host.
    private(set) var lastReload: ReloadKind?

    enum ReloadKind: Equatable { case build, hotReload }

    /// True while the preview runs in the iOS Simulator (an iOS target): the window is the device's,
    /// so sizes and windows do not apply, and the device is chosen by type.
    private(set) var isSimulatorPreview = false
    /// The phones and tablets the simulator's runtime offers, once a preview has prepared it.
    private(set) var simulatorDeviceTypes: [IDESimulatorRuntime.DeviceType] = []
    /// The device type the preview is on (or will be on); nil for the runtime's default phone.
    private(set) var simulatorDeviceTypeID: String?

    /// Why the last tap did nothing, for a few seconds: set when the iOS host reports that no route
    /// handled it (`route` `none` in its `ack`). Nil for the macOS host, which takes real events.
    private(set) var inputHint: String?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// Called when a swipe on a row of an iOS preview offered actions: the point of the frame and
    /// their names. The canvas shows them as a menu and answers with `perform(customAction:at:)`.
    @ObservationIgnored var swipeActionsHandler: ((CGPoint, [String]) -> Void)?

    /// Forgets how the last frame was made, so a caller waiting for the next reload can tell it from the last.
    func lastReloadReset() { lastReload = nil }

    // MARK: Collaborators

    @ObservationIgnored private let context: IDESwiftUIPreviewContext
    @ObservationIgnored private let runner: any IDESwiftUIPreviewProcessRunning
    @ObservationIgnored private let simulator: any IDESimulatorControlling
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

    /// True when the frame is the panel's own size: zoom then changes the window, not just the scale.
    var fillsCanvas: Bool { !isSimulatorPreview && sizePreset == .canvas && currentFixedSize == nil }

    /// The device whose bezel is drawn around the frame, if any (a `.fixedLayout` trait is not a device).
    var frameDevice: IDESwiftUIPreviewDevice? {
        guard showsDeviceFrame else { return nil }
        if isSimulatorPreview { return simulatorFrameDevice }
        guard currentFixedSize == nil else { return nil }
        return sizePreset.device
    }

    /// The bezel of the simulator device in use: a known preset's, else a generic modern phone's at the
    /// size of the frame. Tablets have none.
    private var simulatorFrameDevice: IDESwiftUIPreviewDevice? {
        guard let type = simulatorDeviceTypes.first(where: { $0.identifier == simulatorDeviceTypeID }),
              type.productFamily == "iPhone" || type.name.hasPrefix("iPhone") else { return nil }
        if let known = IDESwiftUIPreviewDevice.all.first(where: { $0.name == type.name }) { return known }
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }
        return IDESwiftUIPreviewDevice(
            id: type.identifier, name: type.name, width: Int(frameSize.width.rounded()), height: Int(frameSize.height.rounded()),
            cornerRadius: 55, cutout: .dynamicIsland, safeTop: 0, safeBottom: 0
        )
    }
    @ObservationIgnored private var baseline: Baseline?
    /// The type of the device of the running host (the runtime's default phone when none was chosen).
    @ObservationIgnored private var activeSimulatorDeviceTypeID: String?

    /// What the host process was built from, kept while it runs: what a later save is compared to.
    private struct Baseline {
        var url: URL
        var packageRoot: URL
        var target: String
        var buildSystem: SwiftPreviewBuildPlan.BuildSystem
        var binPath: String
        var modulePaths: [String]
        var toolchain: IDESwiftUIPreviewToolchain
        var stamps: [String: FileStamp]
        var platform: SwiftPreviewBuildPlan.Platform
        var deploymentTarget: String?
        var sdkPath: String?
        /// The device the host runs on; nil for a macOS host.
        var simulatorTarget: IDESimulatorTarget?
        /// The dylib of the thunk the host has loaded: what a host started elsewhere loads again.
        var thunkPath: String
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
        simulator: (any IDESimulatorControlling)? = nil,
        cacheRoot: URL? = nil
    ) {
        self.context = context
        self.runner = runner
        self.simulator = simulator ?? IDESimulatorService.shared
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

    func setTextSize(_ size: TextSize) {
        guard size != textSize else { return }
        textSize = size
        scheduleRender()
    }

    /// Picking a right-to-left language turns the layout direction on, and the other way round.
    func setLanguage(_ language: Language) {
        guard language != self.language else { return }
        self.language = language
        isRightToLeft = language.isRightToLeft
        scheduleRender()
    }

    func setRightToLeft(_ value: Bool) {
        guard value != isRightToLeft else { return }
        isRightToLeft = value
        scheduleRender()
    }

    func setSizePreset(_ preset: SizePreset) {
        guard preset != sizePreset else { return }
        let dropped = dropsPreviewFrame
        sizePreset = preset
        applyFrameChange(from: dropped)
    }

    func setKeepsPreviewFrame(_ value: Bool) {
        guard value != keepsPreviewFrame else { return }
        let dropped = dropsPreviewFrame
        keepsPreviewFrame = value
        applyFrameChange(from: dropped)
    }

    /// A device or a window size replaces what the preview's own frame says.
    var dropsPreviewFrame: Bool {
        // The simulator's window is the device's: there is no chosen size for the frame to override.
        if keepsPreviewFrame || isSimulatorPreview { return false }
        switch sizePreset {
        case .device, .fixed: return true
        case .canvas, .content: return false
        }
    }

    /// Whether the preview in front ends in a fixed `.frame(width:height:)`.
    var previewHasOuterFrame: Bool {
        guard let file = context.activeFile(), blocks.indices.contains(selectedIndex) else { return false }
        return SwiftPreviewBuildPlan.outerFixedFrame(of: blocks[selectedIndex], in: file.text) != nil
    }

    /// The thunk holds the body without that frame, so a change in whether it is dropped loads a
    /// new thunk (about a second, no build); anything else is only a new frame.
    private func applyFrameChange(from wasDropped: Bool) {
        if dropsPreviewFrame != wasDropped, phase == .ready, previewHasOuterFrame {
            refresh()
        } else {
            scheduleRender()
        }
    }

    /// A new zoom. In the canvas size it changes the window too (zoomed out, the window is larger
    /// and shows more), so the frame is drawn again; otherwise only its resolution follows.
    func setZoom(_ newZoom: IDESwiftUIPreviewZoom) {
        let value: IDESwiftUIPreviewZoom
        if let factor = newZoom.factor { value = .scale(IDESwiftUIPreviewZoom.clamped(factor)) } else { value = .fit }
        guard value != zoom else { return }
        zoom = value
        scheduleRender(after: .milliseconds(60))
    }

    func setShowsDeviceFrame(_ value: Bool) {
        showsDeviceFrame = value
    }

    /// The size the canvas has, in points. A change re-renders after a short pause.
    func setViewport(_ size: CGSize) {
        guard size.width >= 20, size.height >= 20 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != viewport else { return }
        viewport = rounded
        scheduleRender(after: .milliseconds(120))
    }

    /// What an iOS preview cannot be driven to do: the host acts from inside the app with public
    /// API (accessibility activation, controls, scroll views, the first responder), so these have no route.
    static let limitedInputExplanation = """
        Works: buttons, toggles, links, tabs, sliders, steppers, menus and pickers (open one, then \
        click an item), text fields and typing, sheets, scrolling and dragging a list, pulling it \
        down to refresh, and swipe actions (drag a row sideways to pick one).
        Not reachable from a preview: drag and long-press gestures, onTapGesture (a Button works), \
        the buttons of an alert, context menus, pinch, and the software keyboard (it is not part of \
        the frame).
        """

    /// Shown for a few seconds after a tap that no route handled.
    static let noRouteHint = "Nothing there takes a tap from the preview"

    /// The hint a host reply calls for: only a release without travel that no route handled.
    static func inputHint(for command: IDESwiftUIPreviewHostCommand, route: String?) -> String? {
        guard case .mouse(let type, _, _) = command, type == "up", route == "none" else { return nil }
        return noRouteHint
    }

    /// The offer of a swipe: where the row is, in frame points, and its action names.
    static func swipeOffer(in event: IDESwiftUIPreviewHostEvent) -> (point: CGPoint, names: [String])? {
        guard event["route"] as? String == "actions",
              let names = event["actions"] as? [String], !names.isEmpty,
              let x = event["x"] as? Double, let y = event["y"] as? Double else { return nil }
        return (CGPoint(x: x, y: y), names)
    }

    /// Runs one of the actions a swipe offered, on the row at `point`.
    func perform(customAction name: String, at point: CGPoint) {
        send([.customAction(x: point.x, y: point.y, name: name)])
    }

    private func noteInputReply(to command: IDESwiftUIPreviewHostCommand, _ event: IDESwiftUIPreviewHostEvent) {
        if let hint = Self.inputHint(for: command, route: event["route"] as? String) {
            inputHint = hint
            hintTask?.cancel()
            hintTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { self?.inputHint = nil }
            }
        }
        if let offer = Self.swipeOffer(in: event) { swipeActionsHandler?(offer.point, offer.names) }
    }

    /// A click at a point of the frame, in points.
    func click(at point: CGPoint) {
        send([.mouse(type: "down", x: point.x, y: point.y), .mouse(type: "up", x: point.x, y: point.y)])
    }

    /// One mouse event (`down`, `dragged`, `up`, `moved`) at a point of the frame, in points.
    func mouse(_ type: String, at point: CGPoint) {
        send([.mouse(type: type, x: point.x, y: point.y)])
    }

    /// A drag from one point of the frame to another, in points.
    func drag(from start: CGPoint, to end: CGPoint) {
        send([
            .mouse(type: "down", x: start.x, y: start.y),
            .mouse(type: "dragged", x: end.x, y: end.y),
            .mouse(type: "up", x: end.x, y: end.y)
        ])
    }

    /// Scrolls the view under `point` by `dx`, `dy` points (positive `dy` brings later content in).
    func scroll(at point: CGPoint, dx: Double, dy: Double) {
        send([.scroll(x: point.x, y: point.y, dx: dx, dy: dy)])
    }

    /// Types characters into the view that has the focus.
    func type(_ text: String) {
        send([.key(kind: "text", value: text)])
    }

    /// An editing command (`deleteBackward:`, `insertNewline:`, `moveLeft:`…) for the focused view.
    func perform(command selector: String) {
        send([.key(kind: "command", value: selector)])
    }

    /// An action (`copy:`, `paste:`, `selectAll:`) down the focused view's responder chain.
    func perform(action selector: String) {
        send([.key(kind: "action", value: selector)])
    }

    /// Sends input to the host and draws the frame it leads to. Input that follows quickly is
    /// ordered after what is in flight, and only the newest frame is drawn.
    private func send(_ commands: [IDESwiftUIPreviewHostCommand]) {
        guard connection != nil, phase == .ready else { return }
        let counter = nextRenderCounter()
        enqueue { [weak self] connection in
            for command in commands {
                let reply = try await connection.request(command)
                self?.noteInputReply(to: command, reply)
            }
            await self?.render(counter: counter)
        }
        // What the input started has not happened yet when that frame is drawn: a SwiftUI sheet was
        // measured attaching about 290 ms after the click, and an animation runs for its duration.
        // One more frame once things settle; typing and dragging only push it back.
        scheduleRender(after: Self.settleDelay)
    }

    /// How long after input the preview is drawn again.
    static let settleDelay: Duration = .milliseconds(450)

    /// Everything said to the host goes through one queue: replies are matched to requests by
    /// order, so two tasks talking at once could swap them.
    @discardableResult
    private func enqueue(
        _ body: @escaping @MainActor (IDESwiftUIPreviewHostConnection) async throws -> Void
    ) -> Task<Void, Never>? {
        guard let connection else { return nil }
        let previous = hostQueue
        let task = Task { [weak self] in
            await previous?.value
            guard self?.connection === connection else { return }
            do {
                try await body(connection)
            } catch {
                self?.hostEnded()
            }
        }
        hostQueue = task
        return task
    }

    @ObservationIgnored private var hostQueue: Task<Void, Never>?

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
        guard await context.ensureTrusted(package) else {
            guard isCurrent(token) else { return }
            return fail(token, "Building a preview runs the package's code. Trust the folder to continue.")
        }
        guard isCurrent(token) else { return }

        // 2b. Which platform the target is for. A macOS target keeps the AppKit host; an iOS one is
        // built for the simulator and shown by an app there (`docs/SWIFTUI_PREVIEW_PLAN.md` §9).
        var platform = SwiftPreviewBuildPlan.Platform.macOS
        isSimulatorPreview = false
        var simulatorTarget: IDESimulatorTarget?
        var simulatorBoot: Task<Void, Error>?
        if case .xcode(let project) = package.buildSystem {
            phase = .building("Reading the target's settings…")
            let command = SwiftPreviewBuildPlan.buildSettingsCommand(project: project, target: package.target)
            let settings = await execute(
                command, toolchain: toolchain, directory: URL(fileURLWithPath: package.root.path), echo: false
            )
            guard isCurrent(token) else { return }
            let native = SwiftPreviewBuildPlan.platformName(fromBuildSettings: settings.output)
            if native == "iphoneos" || native == "iphonesimulator" {
                platform = .iOSSimulator
                isSimulatorPreview = true
                phase = .building("Preparing the iOS Simulator…")
                do {
                    let prepared = try await simulator.prepare(IDESimulatorRequest(
                        minimumVersion: SwiftPreviewBuildPlan.buildSetting("IPHONEOS_DEPLOYMENT_TARGET", fromBuildSettings: settings.output),
                        deviceTypeIdentifier: simulatorDeviceTypeID
                    ))
                    guard isCurrent(token) else { return }
                    simulatorTarget = prepared
                    simulatorDeviceTypes = prepared.runtime.deviceTypes.filter {
                        $0.productFamily == "iPhone" || $0.productFamily == "iPad"
                    }
                    activeSimulatorDeviceTypeID = prepared.device.deviceTypeIdentifier
                    simulatorDeviceTypeID = prepared.device.deviceTypeIdentifier
                    // The device boots while the project builds: the first boot is the slow part.
                    let service = simulator
                    simulatorBoot = Task { try await service.boot(prepared) }
                    append("Previewing on \(prepared.device.name) (\(prepared.runtime.name)).\n")
                } catch {
                    return fail(token, error.localizedDescription)
                }
            }
        }

        // 3. The recipe.
        let directory = workDirectory(for: package.root)
        let plan = makePlan(
            root: package.root, directory: directory, target: package.target, buildSystem: package.buildSystem,
            url: url, text: text, imports: read.1, block: block,
            platform: platform, simulator: simulatorTarget
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
            var message = Self.summary(of: build.output, fallback: "swift build failed.")
            // The host renders macOS SwiftUI, so an iOS target is built against the macOS SDK; when
            // that fails, say why before the compiler's errors read as the project's own fault.
            if let platformCommand = plan.platformCommand {
                let settings = await execute(platformCommand, toolchain: toolchain, directory: root, echo: false)
                guard isCurrent(token) else { return }
                if let platform = SwiftPreviewBuildPlan.platformName(fromBuildSettings: settings.output), platform != "macosx" {
                    message = "\(package.target) is an \(platform) target, and previews render with macOS SwiftUI, "
                        + "so API that only exists on \(platform) does not compile.\n" + message
                }
            }
            return fail(token, message)
        }
        let binPath: String
        var located: IDESwiftUIPreviewArtifacts.Located
        if let known = plan.knownBinPath, let intermediates = plan.intermediatesPath {
            // An Xcode build: products and intermediates are where the command put them.
            binPath = known
            located = IDESwiftUIPreviewArtifacts.Located(
                objects: IDESwiftUIPreviewArtifacts.locateXcode(intermediates: intermediates, architecture: plan.job.architecture),
                modulePaths: []
            )
        } else {
            let binPathResult = await execute(plan.binPathCommand, toolchain: toolchain, directory: root, echo: false)
            guard isCurrent(token) else { return }
            guard binPathResult.succeeded,
                  let reported = binPathResult.output.split(whereSeparator: \.isNewline).last.map(String.init),
                  reported.hasPrefix("/")
            else { return fail(token, "swift could not report where it built.") }
            binPath = reported
            located = IDESwiftUIPreviewArtifacts.locate(binPath: binPath, module: plan.moduleName)
        }
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
            // The simulator's host is an app: its bundle exists before the executable is linked into it.
            if let bundle = plan.hostBundlePath, let infoPlist = plan.hostInfoPlist {
                try IDESwiftUIPreviewHostBundle.create(at: bundle, infoPlist: infoPlist)
            }
        } catch {
            return fail(token, "Could not write the preview sources: \(error.localizedDescription)")
        }
        let link = await execute(plan.hostCommand(binPath: binPath, objects: objects, modulePaths: modulePaths), toolchain: toolchain, directory: root)
        guard isCurrent(token) else { return }
        guard link.succeeded else { return fail(token, Self.summary(of: link.output, fallback: "Linking the preview failed.")) }
        if let bundle = plan.hostBundlePath, let simulatorTarget {
            phase = .building("Installing the preview on the simulator…")
            if let donor = IDESwiftUIPreviewHostBundle.donor(in: binPath, target: package.target) {
                IDESwiftUIPreviewHostBundle.copyResources(from: donor, to: bundle)
            }
            let sign = await runner.run(
                executable: "/usr/bin/codesign", arguments: ["-f", "-s", "-", bundle], workingDirectory: nil, onOutput: { _ in }
            )
            guard isCurrent(token) else { return }
            guard sign.succeeded else { return fail(token, Self.summary(of: sign.output, fallback: "Signing the preview host failed.")) }
            do {
                // Boot first, then install: the device takes apps only once it has started.
                try await simulatorBoot?.value
                guard isCurrent(token) else { return }
                try await simulator.install(bundlePath: bundle, on: simulatorTarget)
            } catch {
                guard isCurrent(token) else { return }
                return fail(token, error.localizedDescription)
            }
        }
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
        let thunkPath = plan.thunkLibraryPath(generation: token)
        guard await startHost(
            plan: plan, token: token, binPath: binPath, simulatorTarget: simulatorTarget,
            thunkPath: thunkPath, directory: directory
        ) else { return }
        framePrefix = plan.framePath(generation: token)
        lastReload = .build
        let stamps = await Task.detached(priority: .userInitiated) { [root = package.root] in
            Self.stamps(under: root, excluding: url)
        }.value
        baseline = Baseline(
            url: url, packageRoot: package.root, target: package.target, buildSystem: package.buildSystem,
            binPath: binPath, modulePaths: modulePaths, toolchain: toolchain, stamps: stamps,
            platform: platform, deploymentTarget: plan.job.deploymentTarget, sdkPath: plan.job.sdkPath,
            simulatorTarget: simulatorTarget, thunkPath: thunkPath
        )
        phase = .ready
        await renderSerially()
        onChange?()
    }

    /// Starts the host of `plan` (a macOS process, or the app on `simulatorTarget`), waits for it and
    /// loads `thunkPath` into it. False when that did not happen: the failure is shown, or the run was
    /// overtaken.
    private func startHost(
        plan: SwiftPreviewBuildPlan, token: Int, binPath: String, simulatorTarget: IDESimulatorTarget?,
        thunkPath: String, directory: URL
    ) async -> Bool {
        endHost()
        let socket = Self.socketPath(for: directory, generation: token)
        socketPath = socket
        do {
            let onOutput: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor [weak self] in self?.append(text) }
            }
            let process: any IDESwiftUIPreviewHostProcess
            if let simulatorTarget {
                process = try simulator.launch(
                    bundleIdentifier: plan.hostBundleIdentifier, arguments: ["--socket", socket],
                    on: simulatorTarget, onOutput: onOutput
                )
            } else {
                process = try runner.startHost(
                    executable: plan.hostExecutablePath(binPath: binPath), arguments: ["--socket", socket],
                    workingDirectory: URL(fileURLWithPath: binPath), onOutput: onOutput
                )
            }
            host = process
            // An app starts in about a second once installed; allow for a slow first launch of the device.
            let connection = try await IDESwiftUIPreviewHostConnection.connect(
                path: socket, attempts: simulatorTarget == nil ? 100 : 400
            )
            guard isCurrent(token) else {
                connection.close()
                process.terminate()
                if host === process { host = nil }
                return false
            }
            self.connection = connection
            let ready = try await connection.nextEvent()
            guard ready.name == "ready" else {
                fail(token, "The preview host did not start.")
                return false
            }
            let loaded = try await connection.request(.load(dylib: thunkPath, generation: token))
            guard isCurrent(token) else { return false }
            guard loaded.isOK else {
                fail(token, "The preview could not be loaded: \(loaded.error ?? "unknown error")")
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(token) else { return false }
            append("Host connection failed: \(error)\n")
            fail(token, "The preview host stopped unexpectedly (\(error)).")
            return false
        }
        return true
    }

    // MARK: Device

    /// Shows the preview on another simulator device. A running preview moves there without a build:
    /// the host app is installed on that device, started, and loads the thunk it had.
    func setSimulatorDeviceType(_ identifier: String) {
        guard identifier != simulatorDeviceTypeID else { return }
        simulatorDeviceTypeID = identifier
        // Without a built host the choice is used by the next build.
        guard isSimulatorPreview, let baseline, baseline.simulatorTarget != nil, phase == .ready else { return }
        generation += 1
        let token = generation
        pipeline?.cancel()
        renderTask?.cancel()
        pipeline = Task { [weak self] in await self?.move(to: identifier, from: baseline, token: token) }
    }

    private func move(to identifier: String, from saved: Baseline, token: Int) async {
        guard let previous = saved.simulatorTarget, blocks.indices.contains(selectedIndex) else { return }
        let directory = workDirectory(for: saved.packageRoot)
        let plan = makePlan(
            root: saved.packageRoot, directory: directory, target: saved.target, buildSystem: saved.buildSystem,
            url: saved.url, text: context.activeFile()?.text ?? "", imports: [], block: blocks[selectedIndex],
            platform: saved.platform, deploymentTarget: saved.deploymentTarget, sdkPath: saved.sdkPath
        )
        guard let bundle = plan.hostBundlePath else { return }
        phase = .building("Moving the preview to the new device…")
        onChange?()
        let target: IDESimulatorTarget
        do {
            target = try await simulator.prepare(IDESimulatorRequest(
                runtimeIdentifier: previous.runtime.identifier, deviceTypeIdentifier: identifier
            ))
            guard isCurrent(token) else { return }
            try await simulator.boot(target)
            guard isCurrent(token) else { return }
            try await simulator.install(bundlePath: bundle, on: target)
        } catch {
            guard isCurrent(token) else { return }
            return fail(token, error.localizedDescription)
        }
        guard isCurrent(token) else { return }
        append("Previewing on \(target.device.name) (\(target.runtime.name)).\n")
        guard await startHost(
            plan: plan, token: token, binPath: saved.binPath, simulatorTarget: target,
            thunkPath: saved.thunkPath, directory: directory
        ) else { return }
        var moved = saved
        moved.simulatorTarget = target
        baseline = moved
        activeSimulatorDeviceTypeID = target.device.deviceTypeIdentifier
        simulatorDeviceTypeID = target.device.deviceTypeIdentifier
        framePrefix = plan.framePath(generation: token)
        lastReload = .build
        phase = .ready
        await renderSerially()
        onChange?()
    }

    @ObservationIgnored private var framePrefix = ""
    @ObservationIgnored private var modulePaths: [String] = []

    private func nextRenderCounter() -> Int {
        renderCounter += 1
        return renderCounter
    }

    private func makePlan(
        root: URL, directory: URL, target: String, buildSystem: SwiftPreviewBuildPlan.BuildSystem,
        url: URL, text: String, imports: [String], block: SwiftPreviewBlock,
        platform: SwiftPreviewBuildPlan.Platform = .macOS, simulator: IDESimulatorTarget? = nil,
        deploymentTarget: String? = nil, sdkPath: String? = nil
    ) -> SwiftPreviewBuildPlan {
        // The simulator has a scratch path and a work directory of its own: the two platforms'
        // intermediates (`Objects-normal/arm64`) would otherwise be linked together.
        let suffix = platform == .macOS ? "" : "-ios"
        let plan = SwiftPreviewBuildPlan(job: .init(
            packageRoot: root.path,
            scratchPath: directory.appendingPathComponent("scratch" + suffix).path,
            workDirectory: directory.appendingPathComponent("work" + suffix).path,
            targetName: target, sourcePath: url.path, sourceText: text,
            imports: imports, block: block,
            deploymentTarget: deploymentTarget ?? simulator?.runtime.version ?? Self.deploymentTarget,
            buildSystem: buildSystem, dropsOuterFrame: dropsPreviewFrame,
            platform: platform, sdkPath: sdkPath ?? simulator?.sdkPath
        ))
        ignoredFrame = plan.droppedFrame
        return plan
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
            root: baseline.packageRoot, directory: directory, target: baseline.target,
            buildSystem: baseline.buildSystem, url: url, text: text, imports: imports, block: block,
            platform: baseline.platform, deploymentTarget: baseline.deploymentTarget, sdkPath: baseline.sdkPath
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
        self.baseline?.thunkPath = plan.thunkLibraryPath(generation: token)
        lastReload = .hotReload
        phase = .ready
        await renderSerially()
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
        renderTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, self.phase == .ready else { return }
            let counter = self.nextRenderCounter()
            self.enqueue { [weak self] _ in await self?.render(counter: counter) }
        }
    }

    /// Draws the current state and returns when the frame is in place.
    private func renderSerially() async {
        let counter = nextRenderCounter()
        await enqueue { [weak self] _ in await self?.render(counter: counter) }?.value
    }

    private func render(counter: Int) async {
        guard let connection, counter == renderCounter else { return }
        var size = viewport
        var fitsContent = false
        switch sizePreset {
        case .canvas: size = IDESwiftUIPreviewLayout.canvasWindowSize(viewport: viewport, zoom: zoom)
        case .content: fitsContent = true
        case .device(let device): size = device.size
        case .fixed(let width, let height): size = CGSize(width: width, height: height)
        }
        // A `.fixedLayout` trait on the preview itself wins.
        if let currentFixedSize {
            size = currentFixedSize
            fitsContent = false
        }
        // The simulator's window is the device's whatever is asked; the host reports what it drew.
        if isSimulatorPreview {
            size = viewport
            fitsContent = false
        }
        // Pixels per point. The canvas window is the panel divided by the zoom, so the factor keeps
        // the image at the panel's own resolution; a fixed frame is only drawn finer when zoomed in.
        let backing = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let factor = zoom.factor ?? 1
        let scale = backing * (fillsCanvas ? factor : max(1, min(factor, 3)))
        // A phone's content keeps clear of its status bar and home indicator.
        let safeArea = currentFixedSize == nil && !isSimulatorPreview
            ? (top: sizePreset.device?.safeTop ?? 0, bottom: sizePreset.device?.safeBottom ?? 0) : (top: 0, bottom: 0)
        let path = framePrefix.replacingOccurrences(of: ".png", with: "-\(counter).png")
        do {
            let reply = try await connection.request(.render(
                generation: generation, width: size.width, height: size.height,
                scale: scale, scheme: colorScheme.rawValue,
                dynamicType: textSize.rawValue, locale: language.identifier, rightToLeft: isRightToLeft,
                fitsContent: fitsContent, safeTop: safeArea.top, safeBottom: safeArea.bottom, output: path
            ))
            // The host says what size it drew when it chose one (the content's own).
            if let width = reply["pointWidth"] as? Double, let height = reply["pointHeight"] as? Double,
               width > 0, height > 0 {
                size = CGSize(width: width, height: height)
            }
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
