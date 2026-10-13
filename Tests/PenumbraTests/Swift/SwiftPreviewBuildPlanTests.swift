import AppKit
import Darwin
import Foundation
import XCTest
@testable import SwiftIntelligence

final class SwiftPreviewBuildPlanTests: XCTestCase {
    // MARK: Fixtures

    private let counterSource = """
    import SwiftUI
    import DSTheme
    import ToyUI

    struct CounterView: View {
        @State private var count = 0
        var body: some View {
            Button("Add \\(count)") { count += 1 }
        }
    }

    #Preview("Counter") {
        @Previewable @State var n = 3
        CounterView().padding(\(0))
    }
    """

    private func plan(
        source: String, target: String = "ToyUI", imports: [String] = ["import SwiftUI", "import DSTheme", "import ToyUI"]
    ) throws -> SwiftPreviewBuildPlan {
        let blocks = SwiftPreviewExtractor.extract(from: source)
        let block = try XCTUnwrap(blocks.first)
        return SwiftPreviewBuildPlan(job: .init(
            packageRoot: "/p/Pkg", scratchPath: "/cache/pv", workDirectory: "/cache/work",
            targetName: target, sourcePath: "/p/Pkg/Sources/ToyUI/CounterView.swift",
            sourceText: source, imports: imports, block: block
        ))
    }

    // MARK: Names and commands

    func testModuleNameReplacesCharactersAnIdentifierCannotHave() {
        XCTAssertEqual(SwiftPreviewBuildPlan.moduleName(forTarget: "ToyUI"), "ToyUI")
        XCTAssertEqual(SwiftPreviewBuildPlan.moduleName(forTarget: "my-app.core"), "my_app_core")
        XCTAssertEqual(SwiftPreviewBuildPlan.moduleName(forTarget: "2D"), "_2D")
    }

    func testBuildBuildsOnlyTheTargetInItsOwnScratchPathWithTheThreeFlags() throws {
        let command = try plan(source: counterSource).buildCommand
        XCTAssertEqual(command.tool, .swift)
        let arguments = command.arguments
        XCTAssertEqual(arguments.first, "build")
        XCTAssertEqual(value(after: "--target", in: arguments), "ToyUI")
        XCTAssertEqual(value(after: "--scratch-path", in: arguments), "/cache/pv")
        XCTAssertEqual(value(after: "--package-path", in: arguments), "/p/Pkg")
        let joined = arguments.joined(separator: " ")
        XCTAssertTrue(joined.contains("-Xswiftc -enable-testing"))
        XCTAssertTrue(joined.contains("-Xswiftc -Xfrontend -Xswiftc -enable-implicit-dynamic"))
        XCTAssertTrue(joined.contains("-Xswiftc -Xfrontend -Xswiftc -enable-private-imports"))
    }

    func testBinPathCommandUsesTheSameFlagsAsTheBuild() throws {
        let plan = try plan(source: counterSource)
        let build = plan.buildCommand.arguments.filter { $0 != "--target" && $0 != "ToyUI" }
        let binPath = plan.binPathCommand.arguments
        XCTAssertTrue(binPath.contains("--show-bin-path"))
        // A different flag set would answer with a different directory.
        for flag in SwiftPreviewBuildPlan.compilerFlags { XCTAssertTrue(binPath.contains(flag)); XCTAssertTrue(build.contains(flag)) }
    }

    func testHostIsLinkedNextToTheObjectsWithAllOfThem() throws {
        let command = try plan(source: counterSource).hostCommand(binPath: "/bin", objects: ["/bin/B.o", "/bin/A.o"])
        XCTAssertEqual(command.tool, .swiftc)
        XCTAssertEqual(value(after: "-o", in: command.arguments), "/bin/UmbraPreviewHost")
        XCTAssertEqual(command.arguments.suffix(2), ["/bin/A.o", "/bin/B.o"])
        XCTAssertTrue(command.arguments.contains("/cache/work/host/main.swift"))
        XCTAssertEqual(value(after: "-target", in: command.arguments), "arm64-apple-macos14.0")
    }

    func testEachGenerationIsItsOwnModuleAndLibrary() throws {
        let plan = try plan(source: counterSource)
        let first = plan.thunkCommand(binPath: "/bin", generation: 1).arguments
        let second = plan.thunkCommand(binPath: "/bin", generation: 2).arguments
        XCTAssertEqual(value(after: "-module-name", in: first), "UmbraPreviewThunk1")
        XCTAssertEqual(value(after: "-module-name", in: second), "UmbraPreviewThunk2")
        XCTAssertEqual(value(after: "-o", in: second), "/cache/work/thunks/libThunk2.dylib")
        XCTAssertTrue(second.contains("/cache/work/thunks/Thunk2.swift"))
        XCTAssertTrue(second.joined(separator: " ").contains("-Xlinker -undefined -Xlinker dynamic_lookup"))
    }

    // MARK: Thunk source

    func testThunkHoldsPrivateImportPreviewableStateAndTheContentAtItsOwnLine() throws {
        let plan = try plan(source: counterSource)
        let thunk = plan.thunkSource()
        XCTAssertTrue(thunk.hasPrefix("@_private(sourceFile: \"CounterView.swift\") import ToyUI\n"))
        XCTAssertTrue(thunk.contains("\n    @State var n = 3\n"))
        XCTAssertTrue(thunk.contains("CounterView().padding(0)"))
        XCTAssertTrue(thunk.contains("@_cdecl(\"umbra_preview_make_view\")"))
        XCTAssertTrue(thunk.contains("@_dynamicReplacement(for: content())"))
        XCTAssertTrue(thunk.contains("import UmbraPreviewSupport"))
        // The content starts where the `@Previewable` statement ends, on line 13; its first line break is
        // that line's, so the view expression reports line 14.
        XCTAssertTrue(thunk.contains("#sourceLocation(file: \"/p/Pkg/Sources/ToyUI/CounterView.swift\", line: 13)"))
        XCTAssertTrue(thunk.contains("#sourceLocation()"))
    }

    func testThunkKeepsOtherImportsOnceAndDropsItsOwnModuleAndDuplicates() throws {
        let thunk = try plan(source: counterSource).thunkSource()
        let lines = thunk.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0 == "import SwiftUI" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "import DSTheme" }.count, 1)
        XCTAssertFalse(lines.contains("import ToyUI"))
    }

    func testCopyThunkHoldsTheFileLineForLineWithThePreviewBlanked() throws {
        let plan = try plan(source: counterSource)
        let thunk = plan.thunkSource(mode: .copy)
        XCTAssertTrue(thunk.hasPrefix("@testable import ToyUI\n"))
        XCTAssertFalse(thunk.contains("@_private"))
        // The file's own declarations are in the thunk, mapped to its first line.
        XCTAssertTrue(thunk.contains("#sourceLocation(file: \"/p/Pkg/Sources/ToyUI/CounterView.swift\", line: 1)\nimport SwiftUI\nimport DSTheme"))
        XCTAssertTrue(thunk.contains("struct CounterView: View {"))
        // The `#Preview` macro is blanked (it would register a preview this process never uses) and
        // its text appears only as the content function, so it occurs once.
        XCTAssertFalse(thunk.contains("#Preview"))
        XCTAssertEqual(thunk.components(separatedBy: "CounterView().padding(0)").count - 1, 1)
        // Blanking keeps every line break, so the lines after it keep their numbers.
        let blanked = SwiftPreviewBuildPlan.blankingPreviewMacros(in: counterSource)
        XCTAssertEqual(blanked.components(separatedBy: "\n").count, counterSource.components(separatedBy: "\n").count)
        XCTAssertTrue(blanked.contains("struct CounterView"))
    }

    func testProviderThunkShowsThePreviewsProperty() throws {
        let source = """
        struct Foo_Previews: PreviewProvider {
            static var previews: some View { Foo() }
        }
        """
        let thunk = try plan(source: source, imports: []).thunkSource()
        XCTAssertTrue(thunk.contains("VStack { Foo_Previews.previews }"))
        XCTAssertFalse(thunk.contains("#sourceLocation(file"))
    }

    func testFixedLayoutTraitGivesTheSize() throws {
        let source = "#Preview(traits: .fixedLayout(width: 320, height: 48.5), .landscapeLeft) { Text(\"a\") }"
        let size = try XCTUnwrap(plan(source: source, imports: []).fixedSize)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 48.5)
        XCTAssertNil(try plan(source: "#Preview(traits: .sizeThatFitsLayout) { Text(\"a\") }", imports: []).fixedSize)
    }

    func testImportedModuleReadsTheFormsAnImportCanTake() {
        XCTAssertEqual(SwiftPreviewBuildPlan.importedModule(of: "import SwiftUI"), "SwiftUI")
        XCTAssertEqual(SwiftPreviewBuildPlan.importedModule(of: "@testable import ToyUI"), "ToyUI")
        XCTAssertEqual(SwiftPreviewBuildPlan.importedModule(of: "import struct Foundation.URL"), "Foundation")
        XCTAssertEqual(SwiftPreviewBuildPlan.importedModule(of: "import Foo.Bar"), "Foo")
        XCTAssertNil(SwiftPreviewBuildPlan.importedModule(of: "let x = 1"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: iOS Simulator

    private func simulatorPlan(
        buildSystem: SwiftPreviewBuildPlan.BuildSystem = .xcode(project: "/p/App/App.xcodeproj")
    ) throws -> SwiftPreviewBuildPlan {
        let source = "import SwiftUI\n#Preview { Text(\"a\") }\n"
        let block = try XCTUnwrap(SwiftPreviewExtractor.extract(from: source).first)
        return SwiftPreviewBuildPlan(job: .init(
            packageRoot: "/p/App", scratchPath: "/cache/scratch-ios", workDirectory: "/cache/work-ios",
            targetName: "App", sourcePath: "/p/App/App/ContentView.swift", sourceText: source,
            imports: ["import SwiftUI"], block: block, deploymentTarget: "27.0", buildSystem: buildSystem,
            platform: .iOSSimulator, sdkPath: "/Xcode/iPhoneSimulator27.0.sdk"
        ))
    }

    func testTheSimulatorCommandsUseTheSimulatorTripleAndSDK() throws {
        let plan = try simulatorPlan()
        XCTAssertEqual(plan.targetTriple, "arm64-apple-ios27.0-simulator")
        for command in [plan.supportCommand, plan.hostCommand(binPath: "/b", objects: ["/b/a.o"]), plan.thunkCommand(binPath: "/b", generation: 1)] {
            XCTAssertEqual(value(after: "-target", in: command.arguments), "arm64-apple-ios27.0-simulator")
            XCTAssertEqual(value(after: "-sdk", in: command.arguments), "/Xcode/iPhoneSimulator27.0.sdk")
        }
        // The macOS plan has no `-sdk` for swiftc (its default SDK is macOS's).
        XCTAssertFalse(try self.plan(source: counterSource).hostCommand(binPath: "/b", objects: []).arguments.contains("-sdk"))
    }

    func testAnXcodeBuildForTheSimulatorUsesItsSDKAndProductsFolder() throws {
        let plan = try simulatorPlan()
        XCTAssertEqual(value(after: "-sdk", in: plan.buildCommand.arguments), "iphonesimulator")
        XCTAssertEqual(plan.knownBinPath, "/cache/scratch-ios/Products/Debug-iphonesimulator")
        XCTAssertEqual(plan.intermediatesPath, "/cache/scratch-ios/Intermediates")
    }

    func testTheSimulatorHostIsAnAppBundleWithItsOwnIdentifier() throws {
        let plan = try simulatorPlan()
        XCTAssertEqual(plan.hostBundlePath, "/cache/work-ios/host-ios/UmbraPreviewHost.app")
        XCTAssertEqual(plan.hostExecutablePath(binPath: "/b"), "/cache/work-ios/host-ios/UmbraPreviewHost.app/UmbraPreviewHost")
        XCTAssertEqual(value(after: "-o", in: plan.hostCommand(binPath: "/b", objects: []).arguments), plan.hostExecutablePath(binPath: "/b"))
        XCTAssertTrue(plan.supportDirectory.hasSuffix("-ios"))
        // Stable per work directory, different between two.
        XCTAssertTrue(plan.hostBundleIdentifier.hasPrefix("com.umbra.preview."))
        XCTAssertEqual(plan.hostBundleIdentifier, try simulatorPlan().hostBundleIdentifier)
        var other = plan
        other.job.workDirectory = "/cache/other"
        XCTAssertNotEqual(other.hostBundleIdentifier, plan.hostBundleIdentifier)
        // The macOS host is a bare executable beside the objects.
        let mac = try self.plan(source: counterSource)
        XCTAssertNil(mac.hostBundlePath)
        XCTAssertEqual(mac.hostExecutablePath(binPath: "/b"), "/b/UmbraPreviewHost")
        XCTAssertNil(mac.hostInfoPlist)
    }

    func testTheSimulatorHostAdoptsTheSceneLifecycle() throws {
        let plan = try simulatorPlan()
        let info = try XCTUnwrap(plan.hostInfoPlist)
        // iOS 27 traps at launch without a scene manifest (Tools/PreviewSpike/ios-simulator).
        XCTAssertTrue(info.contains("UIApplicationSceneManifest"))
        XCTAssertTrue(info.contains("<string>UmbraSceneDelegate</string>"))
        XCTAssertTrue(info.contains("<string>\(plan.hostBundleIdentifier)</string>"))
        XCTAssertTrue(info.contains("<key>MinimumOSVersion</key><string>27.0</string>"))
        let host = plan.hostSource
        XCTAssertTrue(host.contains("UIWindowSceneDelegate"))
        XCTAssertTrue(host.contains("@objc(UmbraSceneDelegate)"))
        XCTAssertTrue(host.contains("drawHierarchy"))
        XCTAssertFalse(host.contains("import AppKit"))
    }

    func testTheSimulatorThunkHandsOverAViewController() throws {
        let text = try simulatorPlan().thunkSource(mode: .copy)
        XCTAssertTrue(text.contains("import UIKit"))
        XCTAssertFalse(text.contains("import AppKit"))
        XCTAssertTrue(text.contains("UIHostingController(rootView: AnyView(UmbraPreviewRoot()))"))
        XCTAssertFalse(text.contains("NSHostingView"))
        XCTAssertTrue(text.contains("@_cdecl(\"umbra_preview_make_view\")"))
    }

    func testBuildSettingsAreReadByName() {
        let output = """
        Build settings for action build and target App:
            IPHONEOS_DEPLOYMENT_TARGET = 18.0
            PLATFORM_NAME = iphoneos
            PRODUCT_NAME = App
        """
        XCTAssertEqual(SwiftPreviewBuildPlan.buildSetting("IPHONEOS_DEPLOYMENT_TARGET", fromBuildSettings: output), "18.0")
        XCTAssertEqual(SwiftPreviewBuildPlan.buildSetting("PRODUCT_NAME", fromBuildSettings: output), "App")
        // A longer name that starts with the one asked for is not it.
        XCTAssertNil(SwiftPreviewBuildPlan.buildSetting("PLATFORM", fromBuildSettings: output))
        XCTAssertNil(SwiftPreviewBuildPlan.buildSetting("MACOSX_DEPLOYMENT_TARGET", fromBuildSettings: output))
    }
}

/// The whole pipeline against a real toolchain: build a package, link the host, compile a thunk,
/// start the host and read back a rendered frame. Needs a display, a toolchain and a minute, so it
/// runs only with `UMBRA_PREVIEW_INTEGRATION=1`.
final class SwiftPreviewPipelineIntegrationTests: XCTestCase {
    private var directory: URL!
    private var host: Process?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_PREVIEW_INTEGRATION"] == "1",
                          "set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        host?.terminate()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private func run(_ command: SwiftPreviewCommand, in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [command.tool == .swift ? "swift" : "swiftc"] + command.arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(command.arguments.prefix(3)) failed:\n\(output)")
        return output
    }

    func testBuildLinkLoadAndRenderAFrame() throws {
        let package = directory.appendingPathComponent("Toy")
        let sources = package.appendingPathComponent("Sources/ToyUI")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Toy", platforms: [.macOS(.v14)],
            targets: [.target(name: "ToyUI"), .target(name: "Broken")]
        )
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // A target that does not compile must not stop the preview of another one.
        let broken = package.appendingPathComponent("Sources/Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "this is not swift".write(to: broken.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let source = """
        import SwiftUI

        struct Banner: View {
            @State private var taps = 0
            var body: some View {
                VStack {
                    Text("Banner \\(Secret.word)").font(.title).foregroundStyle(.red)
                    Button("Tap \\(taps)") { taps += 1 }
                }
                .padding(24)
            }
        }

        private enum Secret { static let word = "private" }

        #Preview("Banner") {
            @Previewable @State var unused = 1
            Banner().frame(width: 300, height: 140)
        }
        """
        let file = sources.appendingPathComponent("Banner.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let blocks = SwiftPreviewExtractor.extract(from: source)
        let block = try XCTUnwrap(blocks.first)
        let work = directory.appendingPathComponent("work")
        let plan = SwiftPreviewBuildPlan(job: .init(
            packageRoot: package.path, scratchPath: directory.appendingPathComponent("scratch").path,
            workDirectory: work.path, targetName: "ToyUI", sourcePath: file.path, sourceText: source,
            imports: ["import SwiftUI"], block: block
        ))
        for sub in ["host", "thunks", "frames"] {
            try FileManager.default.createDirectory(at: work.appendingPathComponent(sub), withIntermediateDirectories: true)
        }

        try run(plan.buildCommand)
        let binPath = try run(plan.binPathCommand).trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        let objects = try FileManager.default.contentsOfDirectory(atPath: binPath)
            .filter { $0.hasSuffix(".o") }.map { binPath + "/" + $0 }
        XCTAssertTrue(objects.contains { $0.hasSuffix("/ToyUI.o") }, "objects: \(objects)")
        XCTAssertFalse(objects.contains { $0.hasSuffix("/Broken.o") })

        try FileManager.default.createDirectory(atPath: plan.supportDirectory, withIntermediateDirectories: true)
        try SwiftPreviewSupportSource.text.write(toFile: plan.supportSourcePath, atomically: true, encoding: .utf8)
        try run(plan.supportCommand)
        try plan.hostSource.write(toFile: plan.hostSourcePath, atomically: true, encoding: .utf8)
        try run(plan.hostCommand(binPath: binPath, objects: objects))
        try plan.thunkSource(generation: 1).write(toFile: plan.thunkSourcePath(generation: 1), atomically: true, encoding: .utf8)
        try run(plan.thunkCommand(binPath: binPath, generation: 1))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath + "/UmbraPreviewHost")
        process.arguments = ["--socket", plan.socketPath]
        try process.run()
        host = process

        let socket = try connect(path: plan.socketPath)
        defer { close(socket) }
        XCTAssertEqual(try readEvent(socket)["event"] as? String, "ready")

        try send(socket, ["cmd": "load", "dylib": plan.thunkLibraryPath(generation: 1), "generation": 1])
        let loaded = try readEvent(socket)
        XCTAssertEqual(loaded["ok"] as? Bool, true, "\(loaded)")

        try send(socket, ["cmd": "render", "generation": 1, "width": 300.0, "height": 140.0, "scale": 2.0,
                          "scheme": "light", "output": plan.framePath(generation: 1)])
        let frame = try readEvent(socket)
        XCTAssertEqual(frame["ok"] as? Bool, true, "\(frame)")
        XCTAssertEqual(frame["width"] as? Int, 600)

        let image = try XCTUnwrap(NSImage(contentsOfFile: plan.framePath(generation: 1)))
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(representation.pixelsWide, 600)
        XCTAssertTrue(containsRed(representation), "the title is red: the view was drawn, text included")

        // A click on the button changes `@State`, so the next frame differs.
        let before = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try send(socket, ["cmd": "mouse", "type": "down", "x": 150.0, "y": 85.0]); _ = try readEvent(socket)
        try send(socket, ["cmd": "mouse", "type": "up", "x": 150.0, "y": 85.0]); _ = try readEvent(socket)
        try send(socket, ["cmd": "render", "generation": 1, "width": 300.0, "height": 140.0, "scale": 2.0,
                          "scheme": "light", "output": plan.framePath(generation: 2)])
        _ = try readEvent(socket)
        let afterImage = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: plan.framePath(generation: 2)))))
        let after = try XCTUnwrap(afterImage.representation(using: .png, properties: [:]))
        XCTAssertNotEqual(before, after, "the tap counter changed")

        try send(socket, ["cmd": "quit"])
    }

    // MARK: Socket helpers

    private func connect(path: String) throws -> Int32 {
        for _ in 0..<100 {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8.prefix($0.count - 1))) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return descriptor }
            close(descriptor)
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("host never listened on \(path)")
    }

    private func send(_ socket: Int32, _ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        _ = data.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
    }

    private func readEvent(_ socket: Int32) throws -> [String: Any] {
        var line = Data()
        var byte: UInt8 = 0
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        while true {
            guard poll(&descriptor, 1, 30_000) > 0 else { throw XCTSkip("no answer from the host in 30 s") }
            if read(socket, &byte, 1) <= 0 { throw XCTSkip("host closed the socket") }
            if byte == 10 { break }
            line.append(byte)
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func containsRed(_ representation: NSBitmapImageRep) -> Bool {
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8, color.greenComponent < 0.35, color.blueComponent < 0.35, color.alphaComponent > 0.9 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: The preview's own frame

    func testAFixedFrameThatEndsTheBodyIsFound() {
        func frame(_ body: String) -> String? { SwiftPreviewBuildPlan.outerFixedFrame(in: body)?.text }
        XCTAssertEqual(frame("Dashboard()\n    .frame(width: 1100, height: 720)\n"), ".frame(width: 1100, height: 720)")
        XCTAssertEqual(frame("Dashboard().frame(width: 320.5, height: 480, alignment: .topLeading)"),
                       ".frame(width: 320.5, height: 480, alignment: .topLeading)")
        XCTAssertEqual(frame("Text(\"x\").frame(width: 200)"), ".frame(width: 200)")
        XCTAssertEqual(frame("Text(\"x\")\n  .frame(height: 60)  "), ".frame(height: 60)")
        XCTAssertEqual(frame("NavigationStack { Home() }.frame(width: 400, height: 300)"), ".frame(width: 400, height: 300)")
    }

    func testOnlyAnOuterFixedFrameIsTaken() {
        func frame(_ body: String) -> String? { SwiftPreviewBuildPlan.outerFixedFrame(in: body)?.text }
        // The view's own layout.
        XCTAssertNil(frame("Home().frame(maxWidth: .infinity)"))
        XCTAssertNil(frame("Home().frame(minWidth: 200, minHeight: 100)"))
        XCTAssertNil(frame("Home().frame(width: 300, maxHeight: .infinity)"))
        XCTAssertNil(frame("Home().frame(width: size, height: size)"))
        // Another modifier follows, or the frame is inside a container.
        XCTAssertNil(frame("Home().frame(width: 300, height: 200).padding()"))
        XCTAssertNil(frame("VStack { Text(\"a\").frame(width: 10, height: 10) }"))
        XCTAssertNil(frame("Home()"))
        XCTAssertNil(frame("Home().frame()"))
        XCTAssertNil(frame(""))
    }

    func testTheThunkLeavesOutTheFrameOnlyWhenAsked() throws {
        let source = """
        import SwiftUI

        #Preview {
            Dashboard()
                .frame(width: 1100, height: 720)
        }
        """
        func thunk(drops: Bool) throws -> (text: String, plan: SwiftPreviewBuildPlan) {
            let block = try XCTUnwrap(SwiftPreviewExtractor.extract(from: source).first)
            let plan = SwiftPreviewBuildPlan(job: .init(
                packageRoot: "/p/Pkg", scratchPath: "/cache/pv", workDirectory: "/cache/work",
                targetName: "ToyUI", sourcePath: "/p/Pkg/Sources/ToyUI/Dashboard.swift",
                sourceText: source, imports: ["import SwiftUI"], block: block, dropsOuterFrame: drops
            ))
            return (plan.thunkSource(mode: .copy), plan)
        }
        let kept = try thunk(drops: false)
        XCTAssertTrue(kept.text.contains(".frame(width: 1100, height: 720)"))
        XCTAssertNil(kept.plan.droppedFrame)

        let dropped = try thunk(drops: true)
        // In the thunk's own copy of the body only: the file's text before it is as written.
        XCTAssertTrue(dropped.text.contains("Dashboard()"))
        XCTAssertFalse(dropped.text.contains(".frame(width: 1100, height: 720)"))
        XCTAssertEqual(dropped.plan.droppedFrame, ".frame(width: 1100, height: 720)")
        // Same number of lines either way, so diagnostics still point at the right line.
        XCTAssertEqual(kept.text.split(separator: "\n", omittingEmptySubsequences: false).count,
                       dropped.text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }
}
