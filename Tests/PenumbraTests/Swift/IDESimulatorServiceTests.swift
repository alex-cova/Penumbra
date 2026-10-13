import AppKit
import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest
@testable import Umbra

/// The iOS Simulator side of SwiftUI previews (`docs/SWIFTUI_PREVIEW_PLAN.md` §9): `simctl`'s JSON
/// and the choices made from it, the service over a scripted `simctl`, the host bundle, how the
/// session routes an iOS target, and, with `UMBRA_PREVIEW_INTEGRATION=1`, a real simulator.
@MainActor
final class IDESimulatorServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-simulator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Fakes

    private final class HostProcess: IDESwiftUIPreviewHostProcess, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var terminations: Int { lock.withLock { count } }
        func terminate() { lock.withLock { count += 1 } }
    }

    /// Answers each command by a closure and remembers what was asked.
    private final class ScriptedRunner: IDESwiftUIPreviewProcessRunning, @unchecked Sendable {
        typealias Answer = @Sendable (_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var started: [[String]] = []
        let answer: Answer
        let launched = HostProcess()

        init(_ answer: @escaping Answer) { self.answer = answer }

        var commands: [[String]] { lock.withLock { calls } }
        var launches: [[String]] { lock.withLock { started } }

        func run(
            executable: String, arguments: [String], workingDirectory: URL?,
            onOutput: @escaping @Sendable (String) -> Void
        ) async -> IDESwiftUIPreviewRunResult {
            lock.withLock { calls.append(arguments) }
            let result = answer(executable, arguments)
            onOutput(result.output)
            return IDESwiftUIPreviewRunResult(status: result.status, output: result.output, cancelled: false)
        }

        func startHost(
            executable: String, arguments: [String], workingDirectory: URL?,
            onOutput: @escaping @Sendable (String) -> Void
        ) throws -> any IDESwiftUIPreviewHostProcess {
            lock.withLock { started.append(arguments) }
            return launched
        }
    }

    private actor FakeSimulator: IDESimulatorControlling {
        var requests: [IDESimulatorRequest] = []
        var minimums: [String?] { requests.map(\.minimumVersion) }
        var booted: [String] = []
        var installed: [String] = []
        var failure: Error?
        let target: IDESimulatorTarget

        init(target: IDESimulatorTarget? = nil, failure: Error? = nil) {
            self.target = target ?? IDESimulatorTarget(
                device: IDESimulatorDevice(
                    udid: "UDID-1", name: "Umbra Preview - iPhone 17", runtimeIdentifier: "rt",
                    deviceTypeIdentifier: "dt", isBooted: false
                ),
                runtime: IDESimulatorRuntime(
                    identifier: "rt", name: "iOS 27.0", version: "27.0",
                    deviceTypes: [
                        .init(identifier: "dt", name: "iPhone 17", productFamily: "iPhone"),
                        .init(identifier: "dt-ipad", name: "iPad Air", productFamily: "iPad"),
                        .init(identifier: "dt-watch", name: "Not a phone", productFamily: "Watch")
                    ]
                ),
                sdkPath: "/Xcode/iPhoneSimulator27.0.sdk"
            )
            self.failure = failure
        }

        func prepare(_ request: IDESimulatorRequest) async throws -> IDESimulatorTarget {
            requests.append(request)
            if let failure { throw failure }
            return target
        }

        func boot(_ target: IDESimulatorTarget) async throws { booted.append(target.device.udid) }
        func install(bundlePath: String, on target: IDESimulatorTarget) async throws { installed.append(bundlePath) }

        nonisolated func launch(
            bundleIdentifier: String, arguments: [String], on target: IDESimulatorTarget,
            onOutput: @escaping @Sendable (String) -> Void
        ) throws -> any IDESwiftUIPreviewHostProcess { HostProcess() }
    }

    // MARK: simctl's JSON

    private let runtimesJSON = """
    {"runtimes":[
      {"isAvailable":true,"version":"26.5","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","platform":"iOS","name":"iOS 26.5",
       "supportedDeviceTypes":[
         {"name":"iPhone 16","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16","productFamily":"iPhone"},
         {"name":"iPad Pro 13-inch","identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13","productFamily":"iPad"}]},
      {"isAvailable":true,"version":"27.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","platform":"iOS","name":"iOS 27.0",
       "supportedDeviceTypes":[
         {"name":"iPad Air","identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air","productFamily":"iPad"},
         {"name":"iPhone 17 Pro","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","productFamily":"iPhone"},
         {"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","productFamily":"iPhone"},
         {"name":"iPhone 18 Pro","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro","productFamily":"iPhone"}]},
      {"isAvailable":true,"version":"11.0","identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-0","platform":"watchOS","name":"watchOS 11.0","supportedDeviceTypes":[]},
      {"isAvailable":false,"version":"28.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-28-0","platform":"iOS","name":"iOS 28.0","supportedDeviceTypes":[]}
    ]}
    """

    func testOnlyAvailableIOSRuntimesAreListedNewestFirst() throws {
        let runtimes = try XCTUnwrap(IDESimulatorCatalog.runtimes(fromJSON: runtimesJSON))
        XCTAssertEqual(runtimes.map(\.version), ["27.0", "26.5"])
        XCTAssertEqual(runtimes[0].deviceTypes.count, 4)
        XCTAssertNil(IDESimulatorCatalog.runtimes(fromJSON: "not json"))
    }

    func testJSONSurroundedByWarningsIsStillRead() {
        let noisy = "warning: something\n" + runtimesJSON + "\ntrailing\n"
        XCTAssertEqual(IDESimulatorCatalog.runtimes(fromJSON: noisy)?.count, 2)
    }

    func testTheRuntimeIsTheNewestOneThatMeetsTheProjectsMinimum() throws {
        let runtimes = try XCTUnwrap(IDESimulatorCatalog.runtimes(fromJSON: runtimesJSON))
        XCTAssertEqual(IDESimulatorCatalog.runtime(in: runtimes, atLeast: nil)?.version, "27.0")
        XCTAssertEqual(IDESimulatorCatalog.runtime(in: runtimes, atLeast: "18.0")?.version, "27.0")
        XCTAssertEqual(IDESimulatorCatalog.runtime(in: runtimes, atLeast: "27.0")?.version, "27.0")
        XCTAssertNil(IDESimulatorCatalog.runtime(in: runtimes, atLeast: "27.1"))
        // Numeric, not textual: 26.10 is newer than 26.5.
        XCTAssertEqual(IDESimulatorCatalog.compare("26.10", "26.5"), .orderedDescending)
    }

    func testThePhoneIsTheHighestPlainIPhone() throws {
        let runtimes = try XCTUnwrap(IDESimulatorCatalog.runtimes(fromJSON: runtimesJSON))
        // 17 is the highest plain "iPhone N"; "iPhone 18 Pro" is not plain.
        XCTAssertEqual(IDESimulatorCatalog.defaultDeviceType(in: runtimes[0])?.name, "iPhone 17")
        XCTAssertEqual(IDESimulatorCatalog.defaultDeviceType(in: runtimes[1])?.name, "iPhone 16")
        let onlyPro = IDESimulatorRuntime(
            identifier: "r", name: "iOS", version: "27.0",
            deviceTypes: [.init(identifier: "x", name: "iPhone 18 Pro", productFamily: "iPhone")]
        )
        XCTAssertEqual(IDESimulatorCatalog.defaultDeviceType(in: onlyPro)?.name, "iPhone 18 Pro")
    }

    func testDevicesCarryTheirRuntimeAndState() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"A","name":"Umbra Preview - iPhone 17","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"dt"},
          {"udid":"B","name":"Broken","state":"Shutdown","isAvailable":false,"deviceTypeIdentifier":"dt"}]}}
        """
        let devices = try XCTUnwrap(IDESimulatorCatalog.devices(fromJSON: json))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].udid, "A")
        XCTAssertTrue(devices[0].isBooted)
        XCTAssertEqual(devices[0].runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    }

    // MARK: The service

    private func simctlRunner(devicesJSON: String = #"{"devices":{}}"#, createOutput: String = "NEW-UDID\n") -> ScriptedRunner {
        let runtimes = runtimesJSON
        return ScriptedRunner { _, arguments in
            if arguments == ["simctl", "list", "-j", "runtimes"] { return (0, runtimes) }
            if arguments == ["simctl", "list", "-j", "devices"] { return (0, devicesJSON) }
            if arguments.first == "--sdk" { return (0, "/Xcode/iPhoneSimulator27.0.sdk\n") }
            if arguments.starts(with: ["simctl", "create"]) { return (0, createOutput) }
            return (0, "")
        }
    }

    func testAMissingDeviceIsCreatedOnTheNewestRuntime() async throws {
        let runner = simctlRunner()
        let service = IDESimulatorService(runner: runner)
        let target = try await service.prepare(IDESimulatorRequest(minimumVersion: "18.0"))
        XCTAssertEqual(target.device.udid, "NEW-UDID")
        XCTAssertEqual(target.device.name, "Umbra Preview - iPhone 17")
        XCTAssertEqual(target.runtime.version, "27.0")
        XCTAssertEqual(target.sdkPath, "/Xcode/iPhoneSimulator27.0.sdk")
        let create = try XCTUnwrap(runner.commands.first { $0.starts(with: ["simctl", "create"]) })
        XCTAssertEqual(create, [
            "simctl", "create", "Umbra Preview - iPhone 17",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        ])
    }

    func testTheDeviceItCreatedIsFoundAgainAndNeverTheUsers() async throws {
        let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"MINE","name":"iPhone 17","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"dt"},
          {"udid":"OURS","name":"Umbra Preview - iPhone 17","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"dt"}]}}
        """
        let runner = simctlRunner(devicesJSON: devices)
        let target = try await IDESimulatorService(runner: runner).prepare(IDESimulatorRequest())
        XCTAssertEqual(target.device.udid, "OURS")
        XCTAssertFalse(runner.commands.contains { $0.starts(with: ["simctl", "create"]) })
    }

    func testNoRuntimeForTheMinimumSaysHowToGetOne() async {
        let service = IDESimulatorService(runner: simctlRunner())
        do {
            _ = try await service.prepare(IDESimulatorRequest(minimumVersion: "30.0"))
            XCTFail("expected an error")
        } catch let error as IDESimulatorError {
            XCTAssertEqual(error, .noRuntime(minimum: "30.0"))
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("iOS 30.0") && text.contains("Components"), text)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testABootThatFindsTheDeviceRunningIsNotAnErrorAndNotOursToStop() async throws {
        let runner = ScriptedRunner { _, arguments in
            if arguments.starts(with: ["simctl", "boot"]) {
                return (149, "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to boot device in current state: Booted\n")
            }
            return (0, "")
        }
        let service = IDESimulatorService(runner: runner)
        let target = try await FakeSimulator().target
        try await service.boot(target)
        await service.shutdownIfBootedByUs(target)
        XCTAssertFalse(runner.commands.contains { $0.starts(with: ["simctl", "shutdown"]) }, "a device it did not boot stays running")
    }

    func testADeviceItBootedIsShutDownOnRequest() async throws {
        let runner = ScriptedRunner { _, _ in (0, "") }
        let service = IDESimulatorService(runner: runner)
        let target = try await FakeSimulator().target
        try await service.boot(target)
        await service.shutdownIfBootedByUs(target)
        XCTAssertTrue(runner.commands.contains(["simctl", "shutdown", "UDID-1"]))
        XCTAssertTrue(runner.commands.contains(["simctl", "bootstatus", "UDID-1"]), "it waits until the device is ready")
    }

    func testABootTurnsOnTheAccessibilityPreferenceBeforeAnAppCanLaunch() async throws {
        let runner = ScriptedRunner { _, _ in (0, "") }
        let target = try await FakeSimulator().target
        try await IDESimulatorService(runner: runner).boot(target)
        let write = ["simctl", "spawn", "UDID-1", "defaults", "write", "com.apple.Accessibility",
                     "ApplicationAccessibilityEnabled", "-bool", "true"]
        let commands = runner.commands
        let status = try XCTUnwrap(commands.firstIndex(of: ["simctl", "bootstatus", "UDID-1"]))
        let preference = try XCTUnwrap(commands.firstIndex(of: write), "SwiftUI publishes its tree only to an app launched with it on")
        XCTAssertLessThan(status, preference, "set on a device that is up, and before the host is launched on it")
        // A booted device is written again: the app that launches next reads it at launch.
        try await IDESimulatorService(runner: runner).boot(target)
        XCTAssertEqual(runner.commands.filter { $0 == write }.count, 2)
    }

    func testAFailedPreferenceWriteCostsInputNotTheBoot() async throws {
        let runner = ScriptedRunner { _, arguments in
            arguments.starts(with: ["simctl", "spawn"]) ? (1, "spawn failed\n") : (0, "")
        }
        let target = try await FakeSimulator().target
        try await IDESimulatorService(runner: runner).boot(target)
    }

    // MARK: Input replies

    private func event(_ fields: [String: Any]) -> IDESwiftUIPreviewHostEvent {
        IDESwiftUIPreviewHostEvent(fields: fields)
    }

    func testOnlyATapThatNoRouteHandledGetsAHint() {
        let up = IDESwiftUIPreviewHostCommand.mouse(type: "up", x: 1, y: 2)
        XCTAssertEqual(IDESwiftUIPreviewSession.inputHint(for: up, route: "none"), IDESwiftUIPreviewSession.noRouteHint)
        for route in ["accessibility", "control", "text", "slider", "stepper", "menu", "drag", nil] {
            XCTAssertNil(IDESwiftUIPreviewSession.inputHint(for: up, route: route), "\(route ?? "nil")")
        }
        // A press or a drag at a scroll limit is not a tap: no hint.
        XCTAssertNil(IDESwiftUIPreviewSession.inputHint(for: .mouse(type: "dragged", x: 1, y: 2), route: "none"))
        XCTAssertNil(IDESwiftUIPreviewSession.inputHint(for: .mouse(type: "down", x: 1, y: 2), route: "none"))
        XCTAssertNil(IDESwiftUIPreviewSession.inputHint(for: .scroll(x: 1, y: 2, dx: 0, dy: 5), route: "none"))
        XCTAssertNil(IDESwiftUIPreviewSession.inputHint(for: .key(kind: "text", value: "a"), route: "none"))
    }

    func testASwipeOfferCarriesTheRowAndTheActionNames() throws {
        let offer = try XCTUnwrap(IDESwiftUIPreviewSession.swipeOffer(in: event([
            "event": "ack", "route": "actions", "actions": ["Delete", "Archive"], "x": 220.0, "y": 640.0
        ])))
        XCTAssertEqual(offer.names, ["Delete", "Archive"])
        XCTAssertEqual(offer.point, CGPoint(x: 220, y: 640))
        XCTAssertNil(IDESwiftUIPreviewSession.swipeOffer(in: event(["event": "ack", "route": "scroll"])))
        XCTAssertNil(IDESwiftUIPreviewSession.swipeOffer(in: event([
            "event": "ack", "route": "actions", "actions": [String](), "x": 1.0, "y": 2.0
        ])), "an offer with nothing in it is not a menu")
    }

    func testTheCustomActionCommandNamesTheRowAndTheAction() {
        let json = IDESwiftUIPreviewHostCommand.customAction(x: 220, y: 640, name: "Delete").json
        XCTAssertEqual(json["cmd"] as? String, "customAction")
        XCTAssertEqual(json["name"] as? String, "Delete")
        XCTAssertEqual(json["x"] as? Double, 220)
        XCTAssertEqual(json["y"] as? Double, 640)
    }

    func testABootThatFailsReportsTheReason() async throws {
        let runner = ScriptedRunner { _, arguments in
            arguments.starts(with: ["simctl", "boot"]) ? (1, "Unable to boot: Operation not permitted\n") : (0, "")
        }
        let target = try await FakeSimulator().target
        do {
            try await IDESimulatorService(runner: runner).boot(target)
            XCTFail("expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Booting Umbra Preview - iPhone 17 failed") && text.contains("Operation not permitted"), text)
        }
    }

    func testARequestedDeviceTypeIsUsedWhenTheRuntimeHasItAndAPinnedRuntimeStays() async throws {
        // Asked for on the newest runtime: that type.
        let first = simctlRunner()
        let wanted = try await IDESimulatorService(runner: first).prepare(IDESimulatorRequest(
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        ))
        XCTAssertEqual(wanted.device.name, "Umbra Preview - iPhone 17 Pro")
        XCTAssertEqual(wanted.runtime.version, "27.0")

        // A pinned runtime is kept even though a newer one exists, and a type it lacks falls back to its phone.
        let second = simctlRunner()
        let pinned = try await IDESimulatorService(runner: second).prepare(IDESimulatorRequest(
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        ))
        XCTAssertEqual(pinned.runtime.version, "26.5")
        XCTAssertEqual(pinned.device.name, "Umbra Preview - iPhone 16")
    }

    func testOnlyTwoOfItsDevicesStayBooted() async throws {
        let runner = ScriptedRunner { _, _ in (0, "") }
        let service = IDESimulatorService(runner: runner)
        let base = try await FakeSimulator().target
        func target(_ udid: String) -> IDESimulatorTarget {
            var copy = base
            copy.device.udid = udid
            return copy
        }
        try await service.boot(target("A"))
        try await service.boot(target("B"))
        XCTAssertFalse(runner.commands.contains { $0.starts(with: ["simctl", "shutdown"]) })
        try await service.boot(target("C"))
        XCTAssertTrue(runner.commands.contains(["simctl", "shutdown", "A"]), "the oldest goes")
        XCTAssertFalse(runner.commands.contains(["simctl", "shutdown", "B"]))
        XCTAssertFalse(runner.commands.contains(["simctl", "shutdown", "C"]), "never the one just booted")
    }

    func testLaunchPassesTheSocketAndTerminateStopsTheAppToo() async throws {
        let runner = ScriptedRunner { _, _ in (0, "") }
        let service = IDESimulatorService(runner: runner)
        let target = try await FakeSimulator().target
        let process = try service.launch(
            bundleIdentifier: "com.umbra.preview.abc", arguments: ["--socket", "/tmp/s.sock"], on: target, onOutput: { _ in }
        )
        XCTAssertEqual(runner.launches, [[
            "simctl", "launch", "--console", "--terminate-running-process", "UDID-1", "com.umbra.preview.abc",
            "--socket", "/tmp/s.sock"
        ]])
        process.terminate()
        XCTAssertEqual(runner.launched.terminations, 1, "the launcher is stopped")
        let ended = await waitUntil { runner.commands.contains(["simctl", "terminate", "UDID-1", "com.umbra.preview.abc"]) }
        XCTAssertTrue(ended, "and so is the app, which the launcher's end does not do")
    }

    // MARK: The host bundle

    func testTheBundleHoldsTheInfoPlistAndTheResourcesOfTheApp() throws {
        let fm = FileManager.default
        let bin = directory.appendingPathComponent("Debug-iphonesimulator").path
        let app = bin + "/Shown.app"
        try fm.createDirectory(atPath: app + "/en.lproj", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: app + "/_CodeSignature", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: app + "/Frameworks", withIntermediateDirectories: true)
        try Data("car".utf8).write(to: URL(fileURLWithPath: app + "/Assets.car"))
        try Data("strings".utf8).write(to: URL(fileURLWithPath: app + "/en.lproj/Localizable.strings"))
        try Data("exe".utf8).write(to: URL(fileURLWithPath: app + "/Shown"))
        let donorInfo: NSDictionary = ["CFBundleExecutable": "Shown", "CFBundleIdentifier": "com.example.shown"]
        donorInfo.write(toFile: app + "/Info.plist", atomically: true)

        XCTAssertEqual(IDESwiftUIPreviewHostBundle.donor(in: bin, target: "Shown"), app)
        // One `.app` is the donor even when it is named otherwise; two of them are not guessed between.
        XCTAssertEqual(IDESwiftUIPreviewHostBundle.donor(in: bin, target: "Other"), app)
        try fm.createDirectory(atPath: bin + "/Extra.app", withIntermediateDirectories: true)
        XCTAssertNil(IDESwiftUIPreviewHostBundle.donor(in: bin, target: "Other"))
        XCTAssertEqual(IDESwiftUIPreviewHostBundle.donor(in: bin, target: "Shown"), app)

        let bundle = directory.appendingPathComponent("host/UmbraPreviewHost.app").path
        try IDESwiftUIPreviewHostBundle.create(at: bundle, infoPlist: "<plist>host</plist>")
        try Data("linked".utf8).write(to: URL(fileURLWithPath: bundle + "/UmbraPreviewHost"))
        let copied = IDESwiftUIPreviewHostBundle.copyResources(from: app, to: bundle)

        XCTAssertEqual(Set(copied), ["Assets.car", "en.lproj"])
        XCTAssertEqual(try String(contentsOfFile: bundle + "/Info.plist", encoding: .utf8), "<plist>host</plist>", "the host's own Info.plist")
        XCTAssertEqual(try String(contentsOfFile: bundle + "/UmbraPreviewHost", encoding: .utf8), "linked", "not the app's executable")
        XCTAssertFalse(fm.fileExists(atPath: bundle + "/Shown"))
        XCTAssertFalse(fm.fileExists(atPath: bundle + "/_CodeSignature"))
        XCTAssertFalse(fm.fileExists(atPath: bundle + "/Frameworks"))

        // A second bundle replaces the first completely: no old executable, no old signature.
        try IDESwiftUIPreviewHostBundle.create(at: bundle, infoPlist: "<plist>two</plist>")
        XCTAssertFalse(fm.fileExists(atPath: bundle + "/UmbraPreviewHost"))
        XCTAssertFalse(fm.fileExists(atPath: bundle + "/Assets.car"))
    }

    // MARK: Routing in the session

    private let url = URL(fileURLWithPath: "/p/App/App/ContentView.swift")
    private let source = "import SwiftUI\n#Preview { Text(\"a\") }\n"

    private func makeSession(
        runner: any IDESwiftUIPreviewProcessRunning, simulator: any IDESimulatorControlling
    ) -> IDESwiftUIPreviewSession {
        let context = IDESwiftUIPreviewContext(
            activeFile: { [url, source] in (url, source) },
            package: { _ in
                IDESwiftUIPreviewPackage(
                    root: URL(fileURLWithPath: "/p/App"), target: "App", buildSystem: .xcode(project: "/p/App/App.xcodeproj")
                )
            },
            ensureTrusted: { _ in true },
            toolchain: { IDESwiftUIPreviewToolchain(swift: "/usr/bin/swift", swiftc: "/usr/bin/swiftc") },
            publishDiagnostics: { _ in },
            bufferText: { _ in nil }
        )
        return IDESwiftUIPreviewSession(
            context: context, runner: runner, simulator: simulator, cacheRoot: directory.appendingPathComponent("cache")
        )
    }

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func xcodeRunner(platform: String, minimum: String? = "18.0") -> ScriptedRunner {
        ScriptedRunner { _, arguments in
            if arguments.contains("-showBuildSettings") {
                return (0, "Build settings for action build and target App:\n    PLATFORM_NAME = \(platform)\n"
                    + (minimum.map { "    IPHONEOS_DEPLOYMENT_TARGET = \($0)\n" } ?? ""))
            }
            // The build itself fails, so the test sees exactly what was asked of it and nothing after.
            return (1, "/p/App/App/ContentView.swift:2:1: error: stop here\n")
        }
    }

    func testAnIOSTargetIsBuiltForTheSimulatorWhileItsDeviceBoots() async throws {
        let runner = xcodeRunner(platform: "iphoneos", minimum: "18.0")
        let simulator = FakeSimulator()
        let session = makeSession(runner: runner, simulator: simulator)
        session.refresh()
        let failed = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(failed, "\(session.phase)")

        let commands = runner.commands
        XCTAssertTrue(commands[0].contains("-showBuildSettings"))
        let build = try XCTUnwrap(commands.dropFirst().first)
        let sdk = try XCTUnwrap(build.firstIndex(of: "-sdk"))
        XCTAssertEqual(build[sdk + 1], "iphonesimulator")
        XCTAssertTrue(build.contains { $0.hasPrefix("SYMROOT=") && $0.contains("scratch-ios") }, "its own scratch path")
        let minimums = await simulator.minimums
        XCTAssertEqual(minimums, ["18.0"], "the project's deployment target picks the runtime")
        let booted = await waitUntilAsync { await simulator.booted == ["UDID-1"] }
        XCTAssertTrue(booted, "the device was booted without waiting for the build")
    }

    func testAMacOSTargetNeverTouchesTheSimulator() async throws {
        let runner = xcodeRunner(platform: "macosx", minimum: nil)
        let simulator = FakeSimulator()
        let session = makeSession(runner: runner, simulator: simulator)
        session.refresh()
        let failed = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(failed, "\(session.phase)")
        let build = try XCTUnwrap(runner.commands.dropFirst().first)
        XCTAssertEqual(build[try XCTUnwrap(build.firstIndex(of: "-sdk")) + 1], "macosx")
        let minimums = await simulator.minimums
        XCTAssertTrue(minimums.isEmpty)
    }

    func testAnIOSTargetWithoutARuntimeFailsBeforeBuildingAnything() async {
        let runner = xcodeRunner(platform: "iphoneos")
        let simulator = FakeSimulator(failure: IDESimulatorError.noRuntime(minimum: "18.0"))
        let session = makeSession(runner: runner, simulator: simulator)
        session.refresh()
        let failed = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(failed, "\(session.phase)")
        guard case .failed(let message) = session.phase else { return }
        XCTAssertTrue(message.contains("Components"), message)
        XCTAssertEqual(runner.commands.count, 1, "only the settings were read")
    }

    func testTheChosenDeviceIsKeptForTheBuildAndTheBezelFollowsIt() async throws {
        let runner = xcodeRunner(platform: "iphoneos")
        let simulator = FakeSimulator()
        let session = makeSession(runner: runner, simulator: simulator)
        XCTAssertFalse(session.isSimulatorPreview)
        // Chosen before anything is built: remembered, and asked for.
        session.setSimulatorDeviceType("dt-ipad")
        session.refresh()
        let failed = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(failed, "\(session.phase)")
        let requests = await simulator.requests
        XCTAssertEqual(requests.first?.deviceTypeIdentifier, "dt-ipad")

        XCTAssertTrue(session.isSimulatorPreview)
        XCTAssertEqual(session.simulatorDeviceTypes.map(\.name), ["iPhone 17", "iPad Air"], "phones and tablets only")
        // The device the fake gave is the iPhone 17: its bezel is the preset's, and sizes do not apply.
        XCTAssertEqual(session.simulatorDeviceTypeID, "dt")
        XCTAssertEqual(session.frameDevice?.name, "iPhone 17")
        XCTAssertFalse(session.fillsCanvas)
        XCTAssertFalse(session.dropsPreviewFrame)
        session.setSizePreset(.device(IDESwiftUIPreviewDevice.all[0]))
        XCTAssertFalse(session.dropsPreviewFrame, "the simulator's window is the device's, there is no size to impose")
    }

    func testAMacOSBuildAfterAnIOSOneIsNotASimulatorPreview() async throws {
        let ios = xcodeRunner(platform: "iphoneos")
        let session = makeSession(runner: ios, simulator: FakeSimulator())
        session.refresh()
        _ = await waitUntil { if case .failed = session.phase { return true } else { return false } }
        XCTAssertTrue(session.isSimulatorPreview)
        // The same window now previews a macOS target (another project, another file).
        let mac = makeSession(runner: xcodeRunner(platform: "macosx"), simulator: FakeSimulator())
        mac.refresh()
        _ = await waitUntil { if case .failed = mac.phase { return true } else { return false } }
        XCTAssertFalse(mac.isSimulatorPreview)
        XCTAssertNil(mac.frameDevice)
    }

    private func waitUntilAsync(seconds: Double = 5, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: A real simulator

    /// An iOS app from the macOS app template (its SDK and deployment target swapped in the
    /// project file), previewed on a real simulator device: a frame the size of a phone, then a
    /// reload of an edited file into the running app.
    func testAnIOSAppIsPreviewedOnTheSimulatorAndReloaded() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let runtimes = await IDESimulatorService().runtimesForTests()
        try XCTSkipIf(runtimes.isEmpty, "no iOS Simulator runtime is installed")

        let fixture = try makeIOSFixture { greeting in
            """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    NavigationStack {
                        List { Text("\(greeting)"); Color(.systemGroupedBackground).frame(height: 40) }
                            .navigationTitle("Shown")
                            .navigationBarTitleDisplayMode(.large)
                    }
                }
            }

            #Preview { ContentView() }
            """
        }
        let (root, project, file) = (fixture.root, fixture.project, fixture.file)
        let source = fixture.source
        var current = source("First")
        try current.write(to: file, atomically: true, encoding: .utf8)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let context = IDESwiftUIPreviewContext(
            activeFile: { (file, current) },
            package: { _ in IDESwiftUIPreviewPackage(root: root, target: "Shown", buildSystem: .xcode(project: project.path)) },
            ensureTrusted: { _ in true },
            toolchain: { .beside(swift: swift) },
            publishDiagnostics: { _ in },
            bufferText: { _ in nil }
        )
        let session = IDESwiftUIPreviewSession(context: context, cacheRoot: directory.appendingPathComponent("cache"))
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        // The first run may create and boot a device.
        let built = await waitUntil(seconds: 420) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(30).joined(separator: "\n"))")
        // Uses the `Color(.systemGroupedBackground)` of iOS: it would not compile on macOS.
        XCTAssertGreaterThan(session.frameSize.height, session.frameSize.width, "a phone's screen is taller than wide")
        XCTAssertGreaterThanOrEqual(session.frameSize.width, 320)
        let first = try XCTUnwrap(session.frame?.tiffRepresentation)
        saveSnapshot(session.frame, named: "ios-first")

        current = source("Second, a longer greeting")
        try current.write(to: file, atomically: true, encoding: .utf8)
        session.lastReloadReset()
        let reloadStarted = Date()
        session.refresh()
        let hot = await waitUntil(seconds: 120) {
            session.lastReload == .hotReload && session.phase == .ready && session.frame?.tiffRepresentation != first
        }
        print("S2 timings: hot reload on the simulator \(String(format: "%.2f", Date().timeIntervalSince(reloadStarted))) s")
        XCTAssertTrue(hot, "phase \(session.phase) last \(String(describing: session.lastReload))\n\(session.log.suffix(15).joined(separator: "\n"))")
        saveSnapshot(session.frame, named: "ios-reloaded")
        session.stop()
    }

    /// An iOS app from the macOS app template, its SDK and deployment target swapped in the project
    /// file, and `ContentView.swift` written from `source(greeting)`.
    private func makeIOSFixture(
        source: @escaping (String) -> String
    ) throws -> (root: URL, project: URL, file: URL, source: (String) -> String) {
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.xcode.macos-app"))
        let root = try IDEProjectWriter.create(template, options: IDENewProjectOptions(name: "Shown", parentDirectory: directory))
        let project = try XCTUnwrap(IDEXcodeProjectModel.findProject(in: root))
        let definition = project.appendingPathComponent("project.xcproj")
        var text = try String(contentsOf: definition, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"SDKROOT\": \"macosx\"", with: "\"SDKROOT\": \"iphoneos\"")
        text = text.replacingOccurrences(of: "\"MACOSX_DEPLOYMENT_TARGET\": \"15.0\"", with: "\"IPHONEOS_DEPLOYMENT_TARGET\": \"18.0\"")
        try text.write(to: definition, atomically: true, encoding: .utf8)
        return (root, project, root.appendingPathComponent("Shown/ContentView.swift"), source)
    }

    private func makeSimulatorSession(root: URL, project: URL, file: URL, current: @escaping @MainActor () -> String) throws -> IDESwiftUIPreviewSession {
        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let context = IDESwiftUIPreviewContext(
            activeFile: { (file, current()) },
            package: { _ in IDESwiftUIPreviewPackage(root: root, target: "Shown", buildSystem: .xcode(project: project.path)) },
            ensureTrusted: { _ in true },
            toolchain: { .beside(swift: swift) },
            publishDiagnostics: { _ in },
            bufferText: { _ in nil }
        )
        return IDESwiftUIPreviewSession(context: context, cacheRoot: directory.appendingPathComponent("cache"))
    }

    /// What a frame shows, measured: how bright it is, how much of it is ink (what differs from the
    /// background in its corner) and where that ink is horizontally (0 left, 1 right).
    private func measure(_ image: NSImage?) throws -> (luminance: Double, ink: Int, centroidX: Double) {
        let tiff = try XCTUnwrap(image?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        func luminance(_ x: Int, _ y: Int) -> Double {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return 0.299 * Double(color.redComponent) + 0.587 * Double(color.greenComponent) + 0.114 * Double(color.blueComponent)
        }
        let background = luminance(2, bitmap.pixelsHigh - 2)
        var total = 0.0, count = 0, ink = 0, inkX = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                let value = luminance(x, y)
                total += value
                count += 1
                if abs(value - background) > 0.25 {
                    ink += 1
                    inkX += Double(x) / Double(bitmap.pixelsWide)
                }
            }
        }
        return (total / Double(max(count, 1)), ink, ink > 0 ? inkX / Double(ink) : 0.5)
    }

    /// Dark mode, text size, language with its layout direction, and the device are all things the
    /// frame shows, on a real simulator: each is measured, not just compared for being different.
    func testTheEnvironmentAndTheDeviceChangeWhatTheSimulatorDraws() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let runtimes = await IDESimulatorService().runtimesForTests()
        try XCTSkipIf(runtimes.isEmpty, "no iOS Simulator runtime is installed")

        let fixture = try makeIOSFixture { word in
            """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    VStack(alignment: .leading) {
                        Text("\(word)").font(.title)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background { Color(.systemBackground).ignoresSafeArea() }
                }
            }

            #Preview { ContentView() }
            """
        }
        let text = fixture.source("Hello")
        try text.write(to: fixture.file, atomically: true, encoding: .utf8)
        let session = try makeSimulatorSession(root: fixture.root, project: fixture.project, file: fixture.file, current: { text })
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        let started = Date()
        let built = await waitUntil(seconds: 420) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(30).joined(separator: "\n"))")
        XCTAssertTrue(session.isSimulatorPreview)
        let build = Date().timeIntervalSince(started)

        func change(_ name: String, _ action: () -> Void) async throws -> (luminance: Double, ink: Int, centroidX: Double) {
            let before = session.frame?.tiffRepresentation
            action()
            let changed = await waitUntil(seconds: 60) { session.phase == .ready && session.frame?.tiffRepresentation != before }
            XCTAssertTrue(changed, "\(name): the frame did not change; phase \(session.phase)")
            saveSnapshot(session.frame, named: "env-" + name)
            return try measure(session.frame)
        }

        let light = try measure(session.frame)
        saveSnapshot(session.frame, named: "env-light")
        XCTAssertGreaterThan(light.luminance, 0.8, "a white page")
        XCTAssertLessThan(light.centroidX, 0.5, "left to right: the text is at the leading edge, on the left")

        let dark = try await change("dark") { session.setColorScheme(.dark) }
        XCTAssertLessThan(dark.luminance, 0.2, "dark mode: a black page")

        let large = try await change("text-size") { session.setTextSize(.accessibility3) }
        XCTAssertGreaterThan(large.ink, Int(Double(dark.ink) * 1.8), "accessibility text is much bigger: \(dark.ink) → \(large.ink)")

        let arabic = try await change("rtl") {
            session.setLanguage(.init(identifier: "ar", title: "Arabic"))
        }
        XCTAssertTrue(session.isRightToLeft)
        XCTAssertGreaterThan(arabic.centroidX, 0.5, "right to left: the text moves to the leading edge, on the right")

        // The device: another type, on the same runtime, without building again.
        let current = try XCTUnwrap(session.simulatorDeviceTypeID)
        let currentWidth = session.frameSize.width
        XCTAssertFalse(session.simulatorDeviceTypes.isEmpty)
        let other = try XCTUnwrap(session.simulatorDeviceTypes.first { type in
            type.identifier != current && type.productFamily == "iPhone"
                && IDESwiftUIPreviewDevice.all.first { $0.name == type.name }.map { CGFloat($0.width) != currentWidth } == true
        }, "a phone of another width")
        let known = try XCTUnwrap(IDESwiftUIPreviewDevice.all.first { $0.name == other.name })
        let moveStarted = Date()
        session.setSimulatorDeviceType(other.identifier)
        let moved = await waitUntil(seconds: 180) { session.phase == .ready && session.frameSize.width == CGFloat(known.width) }
        XCTAssertTrue(moved, "width \(session.frameSize.width), wanted \(known.width) (\(other.name)); phase \(session.phase)\n\(session.log.suffix(10).joined(separator: "\n"))")
        XCTAssertEqual(session.frameSize.height, CGFloat(known.height))
        let move = Date().timeIntervalSince(moveStarted)
        XCTAssertNotNil(session.frameDevice, "a bezel for the phone that is shown")
        // Still the environment that was chosen: the new host was given it.
        let still = try measure(session.frame)
        XCTAssertLessThan(still.luminance, 0.2, "still dark")
        XCTAssertGreaterThan(still.centroidX, 0.5, "still right to left")
        print("S2 timings: first build \(String(format: "%.1f", build)) s, move to \(other.name) \(String(format: "%.1f", move)) s")
        session.stop()
    }

    /// Input on a real simulator (`docs/SWIFTUI_PREVIEW_IOS_PLAN.md` §3, exit): a button, a switch, a
    /// sheet, a `NavigationLink`, a list of 50 rows and a text field, driven the way the panel drives
    /// them. The app writes its state (and where its controls are) to a file the test reads, so the
    /// assertions are about what the app did, not about pixels.
    func testTapsScrollsAndTypingReachTheAppOnARealSimulator() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        let runtimes = await IDESimulatorService().runtimesForTests()
        try XCTSkipIf(runtimes.isEmpty, "no iOS Simulator runtime is installed")

        let stateFile = directory.appendingPathComponent("state.txt")
        let fixture = try makeIOSFixture { _ in
            #"""
            import SwiftUI
            import Foundation

            struct ContentView: View {
                @State private var taps = 0
                @State private var on = false
                @State private var sheet = false
                @State private var path: [Int] = []
                @State private var name = ""
                @State private var row = 0
                @State private var lastRow = 0
                @State private var slider = 50.0
                @State private var stepper = 0
                @State private var swiped = 0
                @State private var refreshes = 0
                @State private var frames: [String: CGRect] = [:]

                private var summary: String {
                    var lines = ["taps=\(taps)", "on=\(on)", "sheet=\(sheet)", "pushed=\(path.count)",
                                 "name=\(name)", "row=\(row)", "lastRow=\(lastRow)",
                                 "slider=\(Int(slider))", "stepper=\(stepper)", "swiped=\(swiped)",
                                 "refreshes=\(refreshes)"]
                    for (key, f) in frames.sorted(by: { $0.key < $1.key }) {
                        lines.append("frame.\(key)=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
                    }
                    return lines.joined(separator: "\n")
                }

                private func mark(_ id: String) -> some ViewModifier { Mark(id: id, frames: $frames) }

                var body: some View {
                    NavigationStack(path: $path) {
                        List {
                            Button("Tap me") { taps += 1 }.modifier(mark("tap"))
                            Toggle("Switch", isOn: $on).modifier(mark("switch"))
                            Button("Show sheet") { sheet = true }.modifier(mark("sheet"))
                            NavigationLink("Push", value: 1).modifier(mark("push"))
                            TextField("Name", text: $name).modifier(mark("field"))
                            Slider(value: $slider, in: 0...100).modifier(mark("slider"))
                            Stepper("Count \(stepper)", value: $stepper).modifier(mark("stepper"))
                            Text("Swipe me").swipeActions { Button("Delete") { swiped += 1 } }.modifier(mark("swipe"))
                            ForEach(0..<50, id: \.self) { i in
                                Button("Row \(i)") { row = i + 1 }
                                    .onAppear { lastRow = max(lastRow, i) }
                                    .modifier(mark("row\(i)"))
                            }
                        }
                        .navigationTitle("Input")
                        .refreshable { refreshes += 1 }
                        .navigationDestination(for: Int.self) { _ in Text("Detail") }
                        .sheet(isPresented: $sheet) {
                            Button("Close") { sheet = false }.padding(40).modifier(mark("close"))
                        }
                    }
                    .onAppear { save() }
                    .onChange(of: summary) { save() }
                }

                private func save() {
                    try? summary.write(toFile: "\#(stateFile.path)", atomically: true, encoding: .utf8)
                }
            }

            struct Mark: ViewModifier {
                let id: String
                @Binding var frames: [String: CGRect]
                func body(content: Content) -> some View {
                    content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[id] = $0 }
                }
            }

            #Preview { ContentView() }
            """#
        }
        let text = fixture.source("")
        try text.write(to: fixture.file, atomically: true, encoding: .utf8)
        let session = try makeSimulatorSession(root: fixture.root, project: fixture.project, file: fixture.file, current: { text })
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        let built = await waitUntil(seconds: 420) { session.phase == .ready && session.frame != nil }
        XCTAssertTrue(built, "phase \(session.phase)\n\(session.log.suffix(30).joined(separator: "\n"))")

        func state() -> [String: String] {
            guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return [:] }
            var result: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            return result
        }
        func frame(_ id: String) -> CGRect? {
            let numbers = state()["frame." + id]?.split(separator: ",").compactMap { Double($0) }
            guard let n = numbers, n.count == 4 else { return nil }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        func center(_ id: String, dx: Double = 0.5) -> CGPoint? {
            frame(id).map { CGPoint(x: $0.minX + $0.width * dx, y: $0.midY) }
        }
        func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
            let ok = await waitUntil(seconds: 15, condition)
            XCTAssertTrue(ok, "\(what): \(state())")
        }

        await eventually("the app reports where its controls are") { frame("tap") != nil && frame("row0") != nil }

        // A button, a switch (by its label: the row's text side), a field.
        session.click(at: try XCTUnwrap(center("tap")))
        await eventually("a tap on a button runs its action") { state()["taps"] == "1" }
        session.click(at: try XCTUnwrap(center("switch", dx: 0.5)))
        await eventually("a tap on a toggle's row flips it") { state()["on"] == "true" }

        // A sheet: it is drawn, and a button inside it is reachable.
        let beforeSheet = session.frame?.tiffRepresentation
        session.click(at: try XCTUnwrap(center("sheet")))
        await eventually("the sheet is presented") { state()["sheet"] == "true" }
        await eventually("the frame shows it") { session.frame?.tiffRepresentation != beforeSheet }
        saveSnapshot(session.frame, named: "input-sheet")
        await eventually("the sheet's button is placed") { frame("close") != nil }
        session.click(at: try XCTUnwrap(center("close")))
        await eventually("a button inside the sheet dismisses it") { state()["sheet"] == "false" }

        // Text: focus by tap, type, delete.
        session.click(at: try XCTUnwrap(center("field")))
        try await Task.sleep(for: .milliseconds(600))
        session.type("hello")
        await eventually("typing reaches the focused field") { state()["name"] == "hello" }
        session.perform(command: "deleteBackward:")
        await eventually("an editing command reaches it too") { state()["name"] == "hell" }

        // A slider follows a drag, a stepper steps by the half that is pressed.
        let sliderFrame = try XCTUnwrap(frame("slider"))
        session.drag(
            from: CGPoint(x: sliderFrame.minX + sliderFrame.width * 0.1, y: sliderFrame.midY),
            to: CGPoint(x: sliderFrame.minX + sliderFrame.width * 0.8, y: sliderFrame.midY)
        )
        await eventually("a drag along a slider moves it") { (Int(state()["slider"] ?? "0") ?? 0) > 65 }
        let stepperFrame = try XCTUnwrap(frame("stepper"))
        session.click(at: CGPoint(x: stepperFrame.maxX - 35, y: stepperFrame.midY))
        await eventually("the trailing half of a stepper adds") { state()["stepper"] == "1" }
        session.click(at: CGPoint(x: stepperFrame.maxX - 99, y: stepperFrame.midY))
        await eventually("the leading half subtracts") { state()["stepper"] == "0" }

        // A sideways drag on a row with swipe actions offers them; choosing one runs it.
        var offered: (point: CGPoint, names: [String])?
        session.swipeActionsHandler = { point, names in offered = (point, names) }
        let swipeFrame = try XCTUnwrap(frame("swipe"))
        session.drag(
            from: CGPoint(x: swipeFrame.maxX - 60, y: swipeFrame.midY),
            to: CGPoint(x: swipeFrame.maxX - 220, y: swipeFrame.midY)
        )
        await eventually("a swipe offers the row's actions") { offered?.names == ["Delete"] }
        session.perform(customAction: "Delete", at: try XCTUnwrap(offered).point)
        await eventually("the chosen action runs") { state()["swiped"] == "1" }

        // Pulling a list down at its top refreshes it.
        session.drag(from: CGPoint(x: 100, y: 320), to: CGPoint(x: 100, y: 620))
        await eventually("pull to refresh") { state()["refreshes"] == "1" }

        // Scrolling: by the wheel, and by dragging; lazy rows appear and can then be tapped.
        let lastBefore = Int(state()["lastRow"] ?? "0") ?? 0
        let anchor = CGPoint(x: session.frameSize.width / 2, y: session.frameSize.height / 2)
        session.scroll(at: anchor, dx: 0, dy: 800)
        await eventually("a scroll brings later rows in") { (Int(state()["lastRow"] ?? "0") ?? 0) > lastBefore + 8 }
        let visible = try XCTUnwrap((0..<50).first { i in
            frame("row\(i)").map { $0.midY > 160 && $0.midY < Double(session.frameSize.height) - 120 } ?? false
        }, "a row on screen after the scroll")
        let before = try XCTUnwrap(frame("row\(visible)")).minY
        session.drag(from: CGPoint(x: anchor.x, y: anchor.y + 150), to: CGPoint(x: anchor.x, y: anchor.y - 100))
        await eventually("a drag moves the list with the pointer") {
            frame("row\(visible)").map { $0.minY < before - 150 } ?? false
        }
        let tapped = try XCTUnwrap((0..<50).first { i in
            frame("row\(i)").map { $0.midY > 160 && $0.midY < Double(session.frameSize.height) - 120 } ?? false
        })
        session.click(at: try XCTUnwrap(center("row\(tapped)")))
        await eventually("a row that scrolled into view can be tapped") { state()["row"] == "\(tapped + 1)" }
        saveSnapshot(session.frame, named: "input-scrolled")

        // A NavigationLink last: the list is no longer under the pointer afterwards.
        session.scroll(at: anchor, dx: 0, dy: -4000)
        await eventually("back at the top") { (frame("push")?.midY ?? 9999) < 400 }
        session.click(at: try XCTUnwrap(center("push")))
        await eventually("a NavigationLink pushes") { state()["pushed"] == "1" }
        saveSnapshot(session.frame, named: "input-pushed")
        session.stop()
    }

    /// A project of the developer's own, on a real simulator:
    /// `UMBRA_PREVIEW_IOS_PROJECT=<.xcodeproj> UMBRA_PREVIEW_IOS_FILE=<a swift file> UMBRA_PREVIEW_IOS_TARGET=<target>`
    /// (with `UMBRA_PREVIEW_SNAPSHOTS=<dir>` to keep the frame). The project is copied first, so
    /// nothing of it is touched.
    func testAnExistingIOSProjectIsPreviewed() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let projectPath = environment["UMBRA_PREVIEW_IOS_PROJECT"], let filePath = environment["UMBRA_PREVIEW_IOS_FILE"],
              let target = environment["UMBRA_PREVIEW_IOS_TARGET"] else {
            throw XCTSkip("set UMBRA_PREVIEW_IOS_PROJECT, _FILE and _TARGET to preview a project of your own")
        }
        let project = URL(fileURLWithPath: projectPath)
        // Copy the folder that holds the project, so build products and the preview's edits stay out of it.
        let source = project.deletingLastPathComponent()
        let copy = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        let relative = String(filePath.dropFirst(source.path.count))
        let file = copy.appendingPathComponent(relative)
        let text = try String(contentsOf: file, encoding: .utf8)
        let projectCopy = copy.appendingPathComponent(project.lastPathComponent)

        let swift = try XCTUnwrap(IDESwiftPMProjectSystem.resolveSwift(environment: nil))
        let context = IDESwiftUIPreviewContext(
            activeFile: { (file, text) },
            package: { _ in IDESwiftUIPreviewPackage(root: copy, target: target, buildSystem: .xcode(project: projectCopy.path)) },
            ensureTrusted: { _ in true },
            toolchain: { .beside(swift: swift) },
            publishDiagnostics: { _ in },
            bufferText: { _ in nil }
        )
        let session = IDESwiftUIPreviewSession(context: context, cacheRoot: directory.appendingPathComponent("cache"))
        session.setViewport(CGSize(width: 320, height: 200))
        session.refresh()
        let built = await waitUntil(seconds: 600) {
            if case .failed = session.phase { return true }
            return session.phase == .ready && session.frame != nil
        }
        saveSnapshot(session.frame, named: "ios-project")
        XCTAssertTrue(built && session.phase == .ready, "phase \(session.phase)\n\(session.log.suffix(40).joined(separator: "\n"))")
        // `UMBRA_PREVIEW_HOLD=<seconds>` keeps the app running, to compare it with
        // `xcrun simctl io <device> screenshot` (what the simulator itself shows).
        if let hold = environment["UMBRA_PREVIEW_HOLD"].flatMap(Double.init) { try await Task.sleep(for: .seconds(hold)) }
        session.stop()
    }

    /// `UMBRA_PREVIEW_SNAPSHOTS=<dir>` keeps the frames as PNGs, as `UMBRA_VIEW_SNAPSHOTS` does for views.
    private func saveSnapshot(_ image: NSImage?, named name: String) {
        guard let folder = ProcessInfo.processInfo.environment["UMBRA_PREVIEW_SNAPSHOTS"], let image,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}

extension IDESimulatorService {
    /// The iOS runtimes this Mac has, for tests that skip without one.
    fileprivate func runtimesForTests() async -> [IDESimulatorRuntime] {
        let result = await IDESwiftUIPreviewSubprocessRunner().run(
            executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "-j", "runtimes"], workingDirectory: nil, onOutput: { _ in }
        )
        return IDESimulatorCatalog.runtimes(fromJSON: result.output) ?? []
    }
}
