import Foundation
import Testing
@testable import AgentKitMLX

@Suite struct MLXAvailabilityTests {
    private static let all: [MLXAvailabilityStatus] = [.available, .notAppleSilicon, .missingMetalLibrary]

    @Test func everyStatusHasATitleAndMessage() {
        for status in Self.all {
            #expect(!MLXAvailability.title(for: status).isEmpty)
            #expect(!MLXAvailability.message(for: status).isEmpty)
        }
        #expect(MLXAvailability.message(for: .notAppleSilicon).contains("M-series"))
        #expect(MLXAvailability.message(for: .missingMetalLibrary).contains("mlx.metallib"))
    }

    @Test func statusFollowsTheArchitectureAndTheLibrary() {
        let library = URL(fileURLWithPath: "/x/mlx.metallib")
        #if arch(arm64)
        #expect(MLXAvailability.currentStatus(metalLibrary: library) == .available)
        #expect(MLXAvailability.currentStatus(metalLibrary: nil) == .missingMetalLibrary)
        #else
        #expect(MLXAvailability.currentStatus(metalLibrary: library) == .notAppleSilicon)
        #endif
    }
}

@Suite struct MLXMetalLibraryTests {
    private let executable = URL(fileURLWithPath: "/Apps/Umbra.app/Contents/MacOS")
    private let bundleRoot = URL(fileURLWithPath: "/Apps/Umbra.app")

    @Test func searchesInMLXsOwnOrder() {
        let paths = MLXMetalLibrary.candidates(executableDirectory: executable, bundleRoots: [bundleRoot]).map(\.path)
        #expect(paths == [
            "/Apps/Umbra.app/Contents/MacOS/mlx.metallib",
            "/Apps/Umbra.app/Contents/MacOS/Resources/mlx.metallib",
            "/Apps/Umbra.app/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
            "/Apps/Umbra.app/mlx-swift_Cmlx.bundle/default.metallib",
            // Then a plain library in each root, which is where the app packaging puts it.
            "/Apps/Umbra.app/mlx.metallib",
        ])
    }

    @Test func aColocatedLibraryIsFoundAndItsAbsenceIsReported() {
        let colocated = executable.appendingPathComponent("mlx.metallib").path
        #expect(MLXMetalLibrary.locate(executableDirectory: executable, bundleRoots: [bundleRoot], fileExists: { $0.path == colocated })?.path == colocated)
        #expect(MLXMetalLibrary.locate(executableDirectory: executable, bundleRoots: [bundleRoot], fileExists: { _ in false }) == nil)
    }

    @Test func aSwiftPMBundleBesideTheBinaryIsFound() {
        let swiftpm = "/b/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        let found = MLXMetalLibrary.locate(
            executableDirectory: URL(fileURLWithPath: "/b"), bundleRoots: [URL(fileURLWithPath: "/b")], fileExists: { $0.path == swiftpm })
        #expect(found?.path == swiftpm)
    }

    @Test func aRealAppLayoutWithTheLibraryOnlyInResourcesIsFound() throws {
        // The layout Scripts/build-app.sh produces: Umbra.app/Contents/{MacOS/Umbra, Resources/mlx.metallib}.
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("MLXLayout-\(UUID().uuidString)/Umbra.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let roots = [app, resources]
        #expect(MLXMetalLibrary.locate(executableDirectory: macOS, bundleRoots: roots) == nil, "nothing shipped, nothing found")

        let library = resources.appendingPathComponent("mlx.metallib")
        try Data([0]).write(to: library)
        #expect(MLXMetalLibrary.locate(executableDirectory: macOS, bundleRoots: roots)?.path == library.path)
    }
}

