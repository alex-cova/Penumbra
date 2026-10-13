import Foundation
import SubprocessKit
import SwiftIntelligence

/// An iOS runtime that `simctl` lists, with the device types it can run.
struct IDESimulatorRuntime: Equatable, Sendable {
    struct DeviceType: Equatable, Sendable {
        var identifier: String
        var name: String
        var productFamily: String
    }

    var identifier: String
    var name: String
    /// `27.0`.
    var version: String
    var deviceTypes: [DeviceType]
}

/// A simulator device as `simctl list devices` reports it.
struct IDESimulatorDevice: Equatable, Sendable {
    var udid: String
    var name: String
    var runtimeIdentifier: String
    var deviceTypeIdentifier: String
    var isBooted: Bool
}

/// A device Umbra created, as Settings lists it.
struct IDESimulatorOwnDevice: Equatable, Sendable, Identifiable {
    var udid: String
    var name: String
    /// `iOS 27.0`, from the runtime identifier.
    var runtimeName: String
    var state: String
    /// False when the runtime it was made for has been removed: `simctl` lists it but cannot start it.
    var isAvailable: Bool
    var isInUse = false
    /// Bytes on disk, once measured.
    var bytes: Int64?

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
}

/// What the preview needs of a simulator once it has chosen one.
struct IDESimulatorTarget: Equatable, Sendable {
    var device: IDESimulatorDevice
    var runtime: IDESimulatorRuntime
    /// `xcrun --sdk iphonesimulator --show-sdk-path`.
    var sdkPath: String
    /// True when this preparation created the device: its first start is the slow one.
    var wasCreated = false
}

enum IDESimulatorError: Error, Equatable, LocalizedError {
    case noRuntime(minimum: String?)
    case noDeviceType(runtime: String)
    case commandFailed(String, output: String)
    case unreadable(String)
    /// Only the Command Line Tools are installed, or no Xcode is selected: `simctl` is not there.
    case xcodeMissing
    /// The disk is full: creating (or starting) a device writes a few GB.
    case diskFull(String)
    /// CoreSimulatorService did not answer, even after one more try (it restarts at times).
    case serviceUnavailable(String)

    /// What can be done about it in the panel.
    enum Remedy: Equatable, Sendable {
        case installRuntime
        case installXcode
    }

    var remedy: Remedy? {
        switch self {
        case .noRuntime: return .installRuntime
        case .xcodeMissing: return .installXcode
        default: return nil
        }
    }

    /// The error for a failed `simctl`/`xcrun` call, read from what it printed.
    static func classify(_ what: String, output: String) -> IDESimulatorError {
        let text = output.lowercased()
        if text.contains("unable to find utility \"simctl\"") || text.contains("invalid active developer path")
            || text.contains("xcode-select: error") || text.contains("requires xcode") {
            return .xcodeMissing
        }
        if text.contains("no space left on device") || text.contains("nsposixerrordomain code=28")
            || text.contains("not enough free space") || text.contains("disk is full") {
            return .diskFull(what)
        }
        if isServiceFailure(output) { return .serviceUnavailable(what) }
        return .commandFailed(what, output: output)
    }

    /// CoreSimulatorService going away or not answering: worth one more try a moment later.
    static func isServiceFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("coresimulatorservice") || text.contains("connection became invalid")
            || text.contains("unable to connect to simulator service") || text.contains("simulator service")
            || text.contains("xpc_error_connection")
    }

    var errorDescription: String? {
        switch self {
        case .noRuntime(let minimum):
            let need = minimum.map { "iOS \($0) or later" } ?? "an iOS"
            return "No iOS Simulator runtime is installed (\(need)). Install one in Xcode ▸ Settings ▸ Components."
        case .noDeviceType(let runtime):
            return "\(runtime) has no iPhone device type to preview on."
        case .commandFailed(let what, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last.map(String.init)
            return detail.map { "\(what) failed: \($0)" } ?? "\(what) failed."
        case .unreadable(let what):
            return "Could not read \(what) from simctl."
        case .xcodeMissing:
            return "The iOS Simulator comes with Xcode; the Command Line Tools alone do not include it. "
                + "Install Xcode, then choose it with xcode-select -s /Applications/Xcode.app."
        case .diskFull(let what):
            return "\(what) failed: there is not enough free disk space. A simulator device takes a few GB; "
                + "free some space, or remove the devices Umbra created in Settings ▸ SwiftUI Preview."
        case .serviceUnavailable(let what):
            return "\(what) failed: the simulator service did not answer. It restarts by itself after a moment; "
                + "refresh to try again."
        }
    }
}

/// `simctl`'s JSON and the choices made from it: pure, so the rules are tested without a simulator.
enum IDESimulatorCatalog {
    /// The JSON object in `output`, which may have a warning in front of it or behind it.
    static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The available iOS runtimes of `simctl list -j runtimes`, newest first.
    static func runtimes(fromJSON output: String) -> [IDESimulatorRuntime]? {
        guard let object = jsonObject(in: output), let list = object["runtimes"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry -> IDESimulatorRuntime? in
            guard (entry["platform"] as? String) == "iOS" || (entry["identifier"] as? String)?.contains("SimRuntime.iOS") == true,
                  (entry["isAvailable"] as? Bool) ?? true,
                  let identifier = entry["identifier"] as? String, let version = entry["version"] as? String else { return nil }
            let types = (entry["supportedDeviceTypes"] as? [[String: Any]] ?? []).compactMap { type -> IDESimulatorRuntime.DeviceType? in
                guard let id = type["identifier"] as? String, let name = type["name"] as? String else { return nil }
                return IDESimulatorRuntime.DeviceType(identifier: id, name: name, productFamily: type["productFamily"] as? String ?? "")
            }
            return IDESimulatorRuntime(identifier: identifier, name: entry["name"] as? String ?? "iOS \(version)", version: version, deviceTypes: types)
        }
        .sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    /// The available devices of `simctl list -j devices`.
    static func devices(fromJSON output: String) -> [IDESimulatorDevice]? {
        guard let object = jsonObject(in: output), let byRuntime = object["devices"] as? [String: [[String: Any]]] else { return nil }
        var result: [IDESimulatorDevice] = []
        for (runtime, list) in byRuntime {
            for entry in list {
                guard (entry["isAvailable"] as? Bool) ?? true, let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String else { continue }
                result.append(IDESimulatorDevice(
                    udid: udid, name: name, runtimeIdentifier: runtime,
                    deviceTypeIdentifier: entry["deviceTypeIdentifier"] as? String ?? "",
                    isBooted: (entry["state"] as? String) == "Booted"
                ))
            }
        }
        return result
    }

    /// `iOS 27.0` from `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    static func runtimeName(identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = tail.split(separator: "-").map(String.init)
        guard let platform = parts.first else { return identifier }
        return ([platform] + [parts.dropFirst().joined(separator: ".")].filter { !$0.isEmpty }).joined(separator: " ")
    }

    /// The devices Umbra created (by name), available or not, of `simctl list -j devices`.
    static func ownDevices(fromJSON output: String) -> [IDESimulatorOwnDevice]? {
        guard let object = jsonObject(in: output), let byRuntime = object["devices"] as? [String: [[String: Any]]] else { return nil }
        var result: [IDESimulatorOwnDevice] = []
        for (runtime, list) in byRuntime {
            for entry in list {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String,
                      name.hasPrefix(deviceNamePrefix) else { continue }
                result.append(IDESimulatorOwnDevice(
                    udid: udid, name: name, runtimeName: runtimeName(identifier: runtime),
                    state: entry["state"] as? String ?? "Unknown", isAvailable: (entry["isAvailable"] as? Bool) ?? true
                ))
            }
        }
        return result.sorted { ($0.runtimeName, $0.name) < ($1.runtimeName, $1.name) }
    }

    /// Every device Umbra creates starts with this.
    static let deviceNamePrefix = "Umbra Preview - "

    /// `27.0` against `26.5` by numeric components, so `26.10` is newer than `26.5`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    /// The newest runtime that is at least `minimum`, or nil when there is none.
    static func runtime(in runtimes: [IDESimulatorRuntime], atLeast minimum: String?) -> IDESimulatorRuntime? {
        runtimes
            .filter { runtime in minimum.map { compare(runtime.version, $0) != .orderedAscending } ?? true }
            .max { compare($0.version, $1.version) == .orderedAscending }
    }

    /// The phone a preview is shown on when nothing asks for another: the highest-numbered plain
    /// `iPhone N`, else the first iPhone the runtime lists.
    static func defaultDeviceType(in runtime: IDESimulatorRuntime) -> IDESimulatorRuntime.DeviceType? {
        let phones = runtime.deviceTypes.filter { $0.productFamily == "iPhone" || $0.name.hasPrefix("iPhone") }
        func number(_ type: IDESimulatorRuntime.DeviceType) -> Int? {
            let parts = type.name.split(separator: " ")
            guard parts.count == 2, parts[0] == "iPhone" else { return nil }
            return Int(parts[1])
        }
        return phones.compactMap { type in number(type).map { (type, $0) } }.max { $0.1 < $1.1 }?.0 ?? phones.first
    }

    /// The name of the device Umbra creates for a device type; found again by it. A device of the
    /// user's is never reused, so their state and installed apps are left alone.
    static func deviceName(for type: IDESimulatorRuntime.DeviceType) -> String {
        deviceNamePrefix + type.name
    }
}

/// Which device a preview is wanted on.
struct IDESimulatorRequest: Sendable, Equatable, Hashable {
    /// The lowest iOS the project was built for; the runtime is at least this.
    var minimumVersion: String?
    /// A runtime that has to be used (moving a running preview to another device: its objects and
    /// host were compiled for that runtime's version).
    var runtimeIdentifier: String?
    /// The device type to use, when the runtime has it; else the default phone.
    var deviceTypeIdentifier: String?

    init(minimumVersion: String? = nil, runtimeIdentifier: String? = nil, deviceTypeIdentifier: String? = nil) {
        self.minimumVersion = minimumVersion
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }
}

extension IDESimulatorControlling {
    func prepare(_ request: IDESimulatorRequest, progress: @escaping @Sendable (String) -> Void) async throws -> IDESimulatorTarget {
        try await prepare(request)
    }
    func lease(_ target: IDESimulatorTarget) async {}
    func release(_ target: IDESimulatorTarget) async {}
    func removeStaleHosts(on target: IDESimulatorTarget, keeping bundleIdentifiers: Set<String>) async {}
}

/// What the preview session asks of the simulator. The real one is `IDESimulatorService`; tests
/// substitute a fake that records the calls.
protocol IDESimulatorControlling: Sendable {
    /// Finds or creates the device to preview on.
    func prepare(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget
    /// Boots the device if it is not running and returns when it is ready for apps.
    func boot(_ target: IDESimulatorTarget) async throws
    func install(bundlePath: String, on target: IDESimulatorTarget) async throws
    /// `prepare` that says what it is doing ("Creating the device…") while it does it.
    func prepare(_ request: IDESimulatorRequest, progress: @escaping @Sendable (String) -> Void) async throws -> IDESimulatorTarget
    /// A preview session now uses the device: it is not shut down while any session holds a lease.
    func lease(_ target: IDESimulatorTarget) async
    /// The session no longer uses the device. When the last lease goes, the device is shut down
    /// after the idle time if Umbra booted it.
    func release(_ target: IDESimulatorTarget) async
    /// Uninstalls the preview hosts on the device that no session's work directory accounts for.
    func removeStaleHosts(on target: IDESimulatorTarget, keeping bundleIdentifiers: Set<String>) async
    /// Starts the app. The process ends it: `terminate()` stops the launcher and the app.
    func launch(
        bundleIdentifier: String, arguments: [String], on target: IDESimulatorTarget,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any IDESwiftUIPreviewHostProcess
}

/// The only place in Umbra that runs `simctl`. It creates and boots a device of its own
/// (`IDESimulatorCatalog.deviceName`), never one of the user's, and shuts down only what it booted.
actor IDESimulatorService: IDESimulatorControlling {
    private let runner: any IDESwiftUIPreviewProcessRunning
    private let xcrun: String
    /// Devices this service booted, oldest first: the ones it may shut down.
    private var bootedByUs: [String] = []
    /// How many devices of its own stay booted: the one in use and the one before it, so going back
    /// and forth between two phones does not boot each time.
    static let maximumBooted = 2
    private var preparing: [IDESimulatorRequest: Task<IDESimulatorTarget, Error>] = [:]
    /// Sessions using each device, and the shutdown waiting for the last of them to go.
    private var leases: [String: Int] = [:]
    private var idleShutdowns: [String: Task<Void, Never>] = [:]
    /// A fixed idle time (tests); nil reads Settings each time, where 0 minutes means never.
    private let fixedIdleInterval: Duration?
    private let serviceRetryDelay: Duration
    /// What `shutdownBootedByUsBlocking()` reads at quit, when the actor cannot be awaited.
    private let bootedRegistry = BootedRegistry()
    /// The devices this service booted, on disk with the process that booted them: a crash leaves
    /// them running, and the next launch finds them there and takes them over.
    private let ledger: BootedLedger
    private let liveHostIdentifiers: @Sendable () -> Set<String>
    private var orphansAdopted = false

    private var idleInterval: Duration? { fixedIdleInterval ?? IDESwiftUIPreviewSettings.idleInterval }

    /// `ledgerURL` nil keeps no record (tests); `liveHostIdentifiers` is what no work directory
    /// accounts for the complement of; `processIsAlive` says whether a process of the ledger is running.
    init(
        runner: any IDESwiftUIPreviewProcessRunning = IDESwiftUIPreviewSubprocessRunner(), xcrun: String = "/usr/bin/xcrun",
        idleInterval: Duration? = nil,
        serviceRetryDelay: Duration = .milliseconds(1500),
        ledgerURL: URL? = nil,
        processIdentifier: Int32 = getpid(),
        processIsAlive: @escaping @Sendable (Int32) -> Bool = IDESimulatorService.isProcessAlive,
        liveHostIdentifiers: @escaping @Sendable () -> Set<String> = {
            IDESwiftUIPreviewSession.liveHostBundleIdentifiers(cacheRoot: IDESwiftUIPreviewSession.defaultCacheRoot)
        }
    ) {
        self.runner = runner
        self.xcrun = xcrun
        self.fixedIdleInterval = idleInterval
        self.serviceRetryDelay = serviceRetryDelay
        self.ledger = BootedLedger(url: ledgerURL, processIdentifier: processIdentifier, isAlive: processIsAlive)
        self.liveHostIdentifiers = liveHostIdentifiers
    }

    /// Where the app keeps the ledger. Nothing is recorded while tests run with session persistence
    /// off, and the shared service has no ledger until the app turns it on at launch.
    @MainActor static var defaultLedgerURL: URL? {
        guard IDEWorkspace.isSessionPersistenceEnabled,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("com.umbra.editor/SwiftUIPreviews/booted-devices.json")
    }

    /// Starts recording the devices it boots, so a device left running by a crash is found by the
    /// next launch (`adoptOrphans`).
    func enableLedger(at url: URL?) {
        ledger.setURL(url)
    }

    static let isProcessAlive: @Sendable (Int32) -> Bool = { pid in
        // Signal 0 only checks: EPERM means it exists and is another user's.
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The udids of the devices this service booted, readable without awaiting the actor.
    /// The devices Umbra booted and the process that did, as a small JSON file.
    private final class BootedLedger: @unchecked Sendable {
        struct Entry: Codable, Equatable {
            var udid: String
            var pid: Int32
        }

        private let lock = NSLock()
        private var url: URL?
        let processIdentifier: Int32
        let isAlive: @Sendable (Int32) -> Bool

        init(url: URL?, processIdentifier: Int32, isAlive: @escaping @Sendable (Int32) -> Bool) {
            self.url = url
            self.processIdentifier = processIdentifier
            self.isAlive = isAlive
        }

        func setURL(_ url: URL?) { lock.withLock { self.url = url } }

        func entries() -> [Entry] { lock.withLock { read() } }

        func record(_ udid: String) {
            lock.withLock {
                var all = read().filter { $0.udid != udid }
                all.append(Entry(udid: udid, pid: processIdentifier))
                write(all)
            }
        }

        func forget(_ udid: String) {
            lock.withLock {
                let all = read()
                let kept = all.filter { $0.udid != udid }
                if kept.count != all.count { write(kept) }
            }
        }

        /// Entries of a process that is gone: devices a crash left running.
        func orphans() -> [Entry] {
            entries().filter { $0.pid != processIdentifier && !isAlive($0.pid) }
        }

        private func read() -> [Entry] {
            guard let url, let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }

        private func write(_ entries: [Entry]) {
            guard let url else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private final class BootedRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var udids: [String] = []
        var all: [String] { lock.withLock { udids } }
        func add(_ udid: String) { lock.withLock { if !udids.contains(udid) { udids.append(udid) } } }
        func remove(_ udid: String) { lock.withLock { udids.removeAll { $0 == udid } } }
    }

    static let shared = IDESimulatorService()

    /// Runs `simctl`. CoreSimulatorService restarts at times (and when Xcode updates it); a command
    /// that failed because it went away is run once more a moment later.
    private func simctl(_ arguments: [String]) async -> IDESwiftUIPreviewRunResult {
        let first = await runner.run(executable: xcrun, arguments: ["simctl"] + arguments, workingDirectory: nil, onOutput: { _ in })
        guard !first.succeeded, IDESimulatorError.isServiceFailure(first.output) else { return first }
        try? await Task.sleep(for: serviceRetryDelay)
        return await runner.run(executable: xcrun, arguments: ["simctl"] + arguments, workingDirectory: nil, onOutput: { _ in })
    }

    func prepare(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget {
        try await prepare(request, progress: { _ in })
    }

    func prepare(_ request: IDESimulatorRequest, progress: @escaping @Sendable (String) -> Void) async throws -> IDESimulatorTarget {
        if let running = preparing[request] { return try await running.value }
        let task = Task { try await self.findOrCreate(request, progress: progress) }
        preparing[request] = task
        defer { preparing[request] = nil }
        return try await task.value
    }

    private func findOrCreate(
        _ request: IDESimulatorRequest, progress: @Sendable (String) -> Void
    ) async throws -> IDESimulatorTarget {
        let minimumVersion = request.minimumVersion
        let listed = await simctl(["list", "-j", "runtimes"])
        guard listed.succeeded, let runtimes = IDESimulatorCatalog.runtimes(fromJSON: listed.output) else {
            throw IDESimulatorError.classify("Listing the simulator runtimes", output: listed.output)
        }
        let pinned = request.runtimeIdentifier.flatMap { id in runtimes.first { $0.identifier == id } }
        guard let runtime = pinned ?? IDESimulatorCatalog.runtime(in: runtimes, atLeast: minimumVersion) else {
            throw IDESimulatorError.noRuntime(minimum: minimumVersion)
        }
        let wanted = request.deviceTypeIdentifier.flatMap { id in runtime.deviceTypes.first { $0.identifier == id } }
        guard let type = wanted ?? IDESimulatorCatalog.defaultDeviceType(in: runtime) else {
            throw IDESimulatorError.noDeviceType(runtime: runtime.name)
        }
        let sdk = await runner.run(
            executable: xcrun, arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"], workingDirectory: nil, onOutput: { _ in }
        )
        let sdkPath = sdk.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard sdk.succeeded, sdkPath.hasPrefix("/") else {
            throw IDESimulatorError.classify("Finding the iOS Simulator SDK", output: sdk.output)
        }
        let devices = await simctl(["list", "-j", "devices"])
        guard devices.succeeded, let known = IDESimulatorCatalog.devices(fromJSON: devices.output) else {
            throw IDESimulatorError.classify("Listing the simulator devices", output: devices.output)
        }
        adoptOrphans(known: known)
        let name = IDESimulatorCatalog.deviceName(for: type)
        if let existing = known.first(where: { $0.name == name && $0.runtimeIdentifier == runtime.identifier }) {
            return IDESimulatorTarget(device: existing, runtime: runtime, sdkPath: sdkPath)
        }
        progress("Creating the simulator device \(type.name) (first time only)…")
        let created = await simctl(["create", name, type.identifier, runtime.identifier])
        let udid = created.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard created.succeeded, !udid.isEmpty else {
            throw IDESimulatorError.classify("Creating the simulator device", output: created.output)
        }
        let device = IDESimulatorDevice(
            udid: udid, name: name, runtimeIdentifier: runtime.identifier, deviceTypeIdentifier: type.identifier, isBooted: false
        )
        return IDESimulatorTarget(device: device, runtime: runtime, sdkPath: sdkPath, wasCreated: true)
    }

    func boot(_ target: IDESimulatorTarget) async throws {
        let udid = target.device.udid
        let bootStarted = Date()
        let booted = await simctl(["boot", udid])
        // Booted already (a window of ours, or the user's own Simulator): not an error, and not ours to shut down.
        let wasRunning = booted.output.contains("current state: Booted")
        guard booted.succeeded || wasRunning else {
            throw IDESimulatorError.classify("Booting \(target.device.name)", output: booted.output)
        }
        if booted.succeeded, !target.device.isBooted, !bootedByUs.contains(udid) {
            bootedByUs.append(udid)
            bootedRegistry.add(udid)
            ledger.record(udid)
        }
        // Returns when the device is ready for apps (SpringBoard is up).
        let status = await simctl(["bootstatus", udid])
        guard status.succeeded else {
            throw IDESimulatorError.classify("Waiting for \(target.device.name) to start", output: status.output)
        }
        // A cold start is what the next one is told to expect (a boot of a running device takes no time).
        let took = Date().timeIntervalSince(bootStarted)
        if booted.succeeded, !target.device.isBooted, took >= 2 { IDESwiftUIPreviewSettings.lastBootSeconds = took }
        // SwiftUI vends its accessibility tree only to an app that launched with this preference on, and
        // the host taps through that tree (Tools/PreviewSpike/ios-simulator/input-host.swift: a running
        // app does not notice a later change). It is a device of our own, so the preference is ours to
        // set; a failure only costs input, so it does not fail the boot.
        _ = await simctl(Self.accessibilityPreferenceArguments(udid: udid))
        // The oldest of its own devices go, so the Mac does not end up running one per phone tried.
        while bootedByUs.count > Self.maximumBooted, let oldest = bootedByUs.first(where: { $0 != udid }) {
            bootedByUs.removeAll { $0 == oldest }
            bootedRegistry.remove(oldest)
            ledger.forget(oldest)
            _ = await simctl(["shutdown", oldest])
        }
    }

    /// `simctl spawn <udid> defaults write …`: turns on the preference Accessibility Inspector and
    /// XCUITest turn on, which makes a SwiftUI app publish its accessibility elements.
    static func accessibilityPreferenceArguments(udid: String) -> [String] {
        ["spawn", udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"]
    }

    func install(bundlePath: String, on target: IDESimulatorTarget) async throws {
        let result = await simctl(["install", target.device.udid, bundlePath])
        guard result.succeeded else { throw IDESimulatorError.commandFailed("Installing the preview host", output: result.output) }
    }

    nonisolated func launch(
        bundleIdentifier: String, arguments: [String], on target: IDESimulatorTarget,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any IDESwiftUIPreviewHostProcess {
        let udid = target.device.udid
        let launcher = try runner.startHost(
            executable: xcrun,
            arguments: ["simctl", "launch", "--console", "--terminate-running-process", udid, bundleIdentifier] + arguments,
            workingDirectory: nil, onOutput: onOutput
        )
        return SimulatorApp(launcher: launcher, runner: runner, xcrun: xcrun, udid: udid, bundleIdentifier: bundleIdentifier)
    }

    /// Shuts down a device this service booted; one that was running before, or that another window
    /// started, is left running.
    func shutdownIfBootedByUs(_ target: IDESimulatorTarget) async {
        await shutdown(udid: target.device.udid)
    }

    private func shutdown(udid: String) async {
        guard bootedByUs.contains(udid) else { return }
        bootedByUs.removeAll { $0 == udid }
        bootedRegistry.remove(udid)
        ledger.forget(udid)
        _ = await simctl(["shutdown", udid])
    }

    // MARK: Leases and idle shutdown

    func lease(_ target: IDESimulatorTarget) async {
        let udid = target.device.udid
        leases[udid, default: 0] += 1
        idleShutdowns[udid]?.cancel()
        idleShutdowns[udid] = nil
    }

    func release(_ target: IDESimulatorTarget) async {
        let udid = target.device.udid
        guard let count = leases[udid], count > 0 else { return }
        if count > 1 {
            leases[udid] = count - 1
            return
        }
        leases[udid] = nil
        // Nobody is previewing on it any more. A moved preview, a rebuild and a reopened panel come
        // back within the interval and find it running.
        scheduleIdleShutdown(udid: udid)
    }

    private func scheduleIdleShutdown(udid: String) {
        idleShutdowns[udid]?.cancel()
        idleShutdowns[udid] = nil
        // Idle stops switched off in Settings: the device stays until Umbra quits.
        guard let interval = idleInterval else { return }
        idleShutdowns[udid] = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            await self?.idleShutdown(udid: udid)
        }
    }

    private func idleShutdown(udid: String) async {
        idleShutdowns[udid] = nil
        guard (leases[udid] ?? 0) == 0, bootedByUs.contains(udid) else { return }
        // The last chance to uninstall: a device that is shut down cannot be asked for its apps.
        await removeStaleHosts(udid: udid, keeping: liveHostIdentifiers())
        guard (leases[udid] ?? 0) == 0 else { return }
        await shutdown(udid: udid)
    }

    /// Devices an earlier, crashed run of Umbra left booted: they are this service's now, and with
    /// no session using them they go down after the idle time like any other. A device that is
    /// no longer booted is dropped from the ledger, and one whose process still runs is left alone.
    private func adoptOrphans(known: [IDESimulatorDevice]) {
        guard !orphansAdopted else { return }
        orphansAdopted = true
        for entry in ledger.orphans() {
            guard let device = known.first(where: { $0.udid == entry.udid }), device.isBooted else {
                ledger.forget(entry.udid)
                continue
            }
            guard !bootedByUs.contains(entry.udid) else { continue }
            bootedByUs.append(entry.udid)
            bootedRegistry.add(entry.udid)
            ledger.record(entry.udid)
            if (leases[entry.udid] ?? 0) == 0 { scheduleIdleShutdown(udid: entry.udid) }
        }
    }

    /// The udids the service would shut down at quit (for tests).
    func devicesBootedByUs() -> [String] { bootedByUs }

    /// Whether a shutdown is waiting for the device's last lease interval to pass (for tests).
    func hasPendingIdleShutdown(_ target: IDESimulatorTarget) -> Bool { idleShutdowns[target.device.udid] != nil }

    func leaseCount(_ target: IDESimulatorTarget) -> Int { leases[target.device.udid] ?? 0 }

    /// At quit: shuts down every device this service booted, and waits. A pending idle shutdown
    /// would never fire, and the quit would leave the device running.
    nonisolated func shutdownBootedByUsBlocking() {
        let live = liveHostIdentifiers()
        for udid in bootedRegistry.all {
            // Apps no work directory accounts for go while the device can still be asked.
            var listing = SubprocessRequest(executable: xcrun, arguments: ["simctl", "listapps", udid])
            listing.timeout = .seconds(15)
            if let listed = try? SubprocessRunner.runBlocking(listing), listed.exit.status == 0 {
                for identifier in Self.staleHostIdentifiers(listAppsOutput: listed.stdout.text, keeping: live) {
                    var uninstall = SubprocessRequest(executable: xcrun, arguments: ["simctl", "uninstall", udid, identifier])
                    uninstall.timeout = .seconds(15)
                    _ = try? SubprocessRunner.runBlocking(uninstall)
                }
            }
            var request = SubprocessRequest(executable: xcrun, arguments: ["simctl", "shutdown", udid])
            request.timeout = .seconds(15)
            _ = try? SubprocessRunner.runBlocking(request)
            bootedRegistry.remove(udid)
            ledger.forget(udid)
        }
    }

    // MARK: The devices Umbra created (Settings)

    /// The devices whose name says Umbra made them, unavailable ones included.
    func ownDevices() async -> [IDESimulatorOwnDevice] {
        let listed = await simctl(["list", "-j", "devices"])
        guard listed.succeeded, let devices = IDESimulatorCatalog.ownDevices(fromJSON: listed.output) else { return [] }
        return devices.map { device in
            var device = device
            device.isInUse = (leases[device.udid] ?? 0) > 0
            return device
        }
    }

    /// Deletes devices Umbra created. One a preview is using is left, and a running one is shut down
    /// first. Returns the reason for each that was not removed, by udid.
    func removeOwnDevices(udids: [String]) async -> [String: String] {
        let ours = Set(await ownDevices().map(\.udid))
        var failures: [String: String] = [:]
        for udid in udids {
            guard ours.contains(udid) else {
                failures[udid] = "It is not a device Umbra created."
                continue
            }
            if (leases[udid] ?? 0) > 0 {
                failures[udid] = "A preview is using it."
                continue
            }
            idleShutdowns[udid]?.cancel()
            idleShutdowns[udid] = nil
            bootedByUs.removeAll { $0 == udid }
            bootedRegistry.remove(udid)
            ledger.forget(udid)
            _ = await simctl(["shutdown", udid])
            let deleted = await simctl(["delete", udid])
            if !deleted.succeeded {
                failures[udid] = deleted.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "simctl delete failed."
            }
        }
        return failures
    }

    /// Bytes under the device's data folder; nil when it cannot be read (a sandboxed build).
    nonisolated static func sizeOnDisk(udid: String) -> Int64? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Hosts that stay installed

    /// The identifiers `simctl listapps` shows that belong to a preview host and that no live work
    /// directory accounts for. `output` is the old-style property list `listapps` prints, possibly
    /// after a line of warnings.
    static func staleHostIdentifiers(listAppsOutput output: String, keeping live: Set<String>) -> [String] {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return [] }
        return plist.keys
            .filter { $0.hasPrefix(SwiftPreviewBuildPlan.hostBundleIdentifierPrefix) && !live.contains($0) }
            .sorted()
    }

    func removeStaleHosts(on target: IDESimulatorTarget, keeping bundleIdentifiers: Set<String>) async {
        await removeStaleHosts(udid: target.device.udid, keeping: bundleIdentifiers)
    }

    private func removeStaleHosts(udid: String, keeping bundleIdentifiers: Set<String>) async {
        let listed = await simctl(["listapps", udid])
        guard listed.succeeded else { return }
        for identifier in Self.staleHostIdentifiers(listAppsOutput: listed.output, keeping: bundleIdentifiers) {
            _ = await simctl(["uninstall", udid, identifier])
        }
    }

    /// The app of one `simctl launch --console`. Ending the launcher does not end the app, so
    /// `terminate()` asks the device to as well.
    private final class SimulatorApp: IDESwiftUIPreviewHostProcess, @unchecked Sendable {
        let launcher: any IDESwiftUIPreviewHostProcess
        let runner: any IDESwiftUIPreviewProcessRunning
        let xcrun: String
        let udid: String
        let bundleIdentifier: String

        init(launcher: any IDESwiftUIPreviewHostProcess, runner: any IDESwiftUIPreviewProcessRunning,
             xcrun: String, udid: String, bundleIdentifier: String) {
            self.launcher = launcher
            self.runner = runner
            self.xcrun = xcrun
            self.udid = udid
            self.bundleIdentifier = bundleIdentifier
        }

        func terminate() {
            launcher.terminate()
            let runner = runner, xcrun = xcrun, udid = udid, bundleIdentifier = bundleIdentifier
            Task.detached {
                _ = await runner.run(
                    executable: xcrun, arguments: ["simctl", "terminate", udid, bundleIdentifier],
                    workingDirectory: nil, onOutput: { _ in }
                )
            }
        }
    }
}
