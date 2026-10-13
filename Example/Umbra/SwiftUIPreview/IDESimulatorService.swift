import Foundation

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

/// What the preview needs of a simulator once it has chosen one.
struct IDESimulatorTarget: Equatable, Sendable {
    var device: IDESimulatorDevice
    var runtime: IDESimulatorRuntime
    /// `xcrun --sdk iphonesimulator --show-sdk-path`.
    var sdkPath: String
}

enum IDESimulatorError: Error, Equatable, LocalizedError {
    case noRuntime(minimum: String?)
    case noDeviceType(runtime: String)
    case commandFailed(String, output: String)
    case unreadable(String)

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
        "Umbra Preview - \(type.name)"
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

/// What the preview session asks of the simulator. The real one is `IDESimulatorService`; tests
/// substitute a fake that records the calls.
protocol IDESimulatorControlling: Sendable {
    /// Finds or creates the device to preview on.
    func prepare(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget
    /// Boots the device if it is not running and returns when it is ready for apps.
    func boot(_ target: IDESimulatorTarget) async throws
    func install(bundlePath: String, on target: IDESimulatorTarget) async throws
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

    init(runner: any IDESwiftUIPreviewProcessRunning = IDESwiftUIPreviewSubprocessRunner(), xcrun: String = "/usr/bin/xcrun") {
        self.runner = runner
        self.xcrun = xcrun
    }

    static let shared = IDESimulatorService()

    private func simctl(_ arguments: [String]) async -> IDESwiftUIPreviewRunResult {
        await runner.run(executable: xcrun, arguments: ["simctl"] + arguments, workingDirectory: nil, onOutput: { _ in })
    }

    func prepare(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget {
        if let running = preparing[request] { return try await running.value }
        let task = Task { try await self.findOrCreate(request) }
        preparing[request] = task
        defer { preparing[request] = nil }
        return try await task.value
    }

    private func findOrCreate(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget {
        let minimumVersion = request.minimumVersion
        let listed = await simctl(["list", "-j", "runtimes"])
        guard listed.succeeded, let runtimes = IDESimulatorCatalog.runtimes(fromJSON: listed.output) else {
            throw IDESimulatorError.commandFailed("Listing the simulator runtimes", output: listed.output)
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
            throw IDESimulatorError.commandFailed("Finding the iOS Simulator SDK", output: sdk.output)
        }
        let devices = await simctl(["list", "-j", "devices"])
        guard devices.succeeded, let known = IDESimulatorCatalog.devices(fromJSON: devices.output) else {
            throw IDESimulatorError.commandFailed("Listing the simulator devices", output: devices.output)
        }
        let name = IDESimulatorCatalog.deviceName(for: type)
        if let existing = known.first(where: { $0.name == name && $0.runtimeIdentifier == runtime.identifier }) {
            return IDESimulatorTarget(device: existing, runtime: runtime, sdkPath: sdkPath)
        }
        let created = await simctl(["create", name, type.identifier, runtime.identifier])
        let udid = created.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard created.succeeded, !udid.isEmpty else {
            throw IDESimulatorError.commandFailed("Creating the simulator device", output: created.output)
        }
        let device = IDESimulatorDevice(
            udid: udid, name: name, runtimeIdentifier: runtime.identifier, deviceTypeIdentifier: type.identifier, isBooted: false
        )
        return IDESimulatorTarget(device: device, runtime: runtime, sdkPath: sdkPath)
    }

    func boot(_ target: IDESimulatorTarget) async throws {
        let udid = target.device.udid
        let booted = await simctl(["boot", udid])
        // Booted already (a window of ours, or the user's own Simulator): not an error, and not ours to shut down.
        let wasRunning = booted.output.contains("current state: Booted")
        guard booted.succeeded || wasRunning else {
            throw IDESimulatorError.commandFailed("Booting \(target.device.name)", output: booted.output)
        }
        if booted.succeeded, !target.device.isBooted, !bootedByUs.contains(udid) { bootedByUs.append(udid) }
        // Returns when the device is ready for apps (SpringBoard is up).
        let status = await simctl(["bootstatus", udid])
        guard status.succeeded else {
            throw IDESimulatorError.commandFailed("Waiting for \(target.device.name) to start", output: status.output)
        }
        // The oldest of its own devices go, so the Mac does not end up running one per phone tried.
        while bootedByUs.count > Self.maximumBooted, let oldest = bootedByUs.first(where: { $0 != udid }) {
            bootedByUs.removeAll { $0 == oldest }
            _ = await simctl(["shutdown", oldest])
        }
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
        guard bootedByUs.contains(target.device.udid) else { return }
        bootedByUs.removeAll { $0 == target.device.udid }
        _ = await simctl(["shutdown", target.device.udid])
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
