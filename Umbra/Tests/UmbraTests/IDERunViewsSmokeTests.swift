import AppKit
import JavaIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// Hosts the Run views in a window so a crash (a missing environment object, a duplicated list id)
/// or an empty render shows up in the test run. Set `UMBRA_VIEW_SNAPSHOTS` to a folder to keep the images.
@MainActor
final class IDERunViewsSmokeTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var base: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("run-views-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.runConfigurationStore = JavaRunConfigurationCatalog(
            store: JavaRunConfigurationStore(storeURL: base.appendingPathComponent("store.json"))
        )
        workspace.project.setRoot(base)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func render<Content: View>(_ view: Content, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(workspace).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    /// The share of pixels that are not the most common colour: 0 for a blank render.
    private func ink(_ rep: NSBitmapImageRep) -> Double {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
                counts[key, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let common = counts.values.max() else { return 0 }
        return 1 - Double(common) / Double(total)
    }

    private func sampleConfigurations() -> [JavaRunConfiguration] {
        var server = JavaRunConfiguration(
            name: "Server", target: .classpathMain(className: "app.Server", sourceFile: base.appendingPathComponent("Server.java").path),
            programArguments: "--port 8080", vmArguments: "-Xmx512m", environment: ["MODE": "dev"], storeAsProjectFile: true
        )
        server.beforeLaunch = [.gradleTasks([":app:generateSources"])]
        let single = JavaRunConfiguration(target: .singleFile(path: base.appendingPathComponent("Gone.java").path))
        let gradle = JavaRunConfiguration(name: "Boot", target: .gradleRun(projectPath: ":app", taskName: "bootRun"))
        let tests = JavaRunConfiguration(
            name: "Unit tests", target: .gradleTest(taskPath: ":app:test", filters: ["app.FooTest"], sourceFile: nil)
        )
        return [server, single, gradle, tests]
    }

    func testTheEditConfigurationsDialogRenders() throws {
        let configurations = sampleConfigurations()
        let editor = IDERunConfigurationsEditor(
            configurations: configurations,
            templates: Dictionary(uniqueKeysWithValues: JavaRunConfiguration.Kind.allCases.map { ($0, JavaRunConfiguration.defaultTemplate(for: $0)) }),
            highlighting: configurations[0]
        )
        let rep = try render(IDERunConfigurationsWindow(editor: editor), size: NSSize(width: 920, height: 640), name: "edit-configurations")
        XCTAssertGreaterThan(ink(rep), 0.02)

        editor.selection = .configuration(configurations[1].id)
        XCTAssertGreaterThan(ink(try render(IDERunConfigurationsWindow(editor: editor), size: NSSize(width: 920, height: 640), name: "edit-configurations-broken")), 0.02)
        editor.selection = .configuration(configurations[3].id)
        _ = try render(IDERunConfigurationsWindow(editor: editor), size: NSSize(width: 920, height: 640), name: "edit-configurations-junit")
        editor.selection = .template(.application)
        _ = try render(IDERunConfigurationsWindow(editor: editor), size: NSSize(width: 920, height: 640), name: "edit-configurations-template")
    }

    func testTheEmptyDialogRenders() throws {
        let editor = IDERunConfigurationsEditor(configurations: [], templates: [:])
        XCTAssertGreaterThan(ink(try render(IDERunConfigurationsWindow(editor: editor), size: NSSize(width: 920, height: 640), name: "edit-configurations-empty")), 0.01)
    }

    func testTheRunPanelRendersSessionsWithOutput() throws {
        let first = IDERunSession(configuration: sampleConfigurations()[0])
        first.appendNote("java 21 · /jdk")
        first.fail("Build failed, so it was not started: Gradle exited with 1.")
        let second = IDERunSession(configuration: sampleConfigurations()[2])
        second.appendNote("Building :app:classes")
        workspace.runs.add(first)
        workspace.runs.add(second)
        let rep = try render(IDERunPanel(), size: NSSize(width: 800, height: 260), name: "run-panel")
        XCTAssertGreaterThan(ink(rep), 0.01)
        _ = try render(IDERunControls(), size: NSSize(width: 400, height: 30), name: "run-controls")
    }
}
