import Foundation
import Testing
@testable import LocalModelStore

struct LocalModelPathsTests {
    private static let root = URL(fileURLWithPath: "/tmp/models-root", isDirectory: true)

    // MARK: - Repository IDs

    @Test(arguments: [
        "mlx-community/Qwen3-4B-4bit", "owner/name", "a/b", "org.name/model_v1.5", "Org-1/Model-2",
    ])
    func acceptsValidRepositoryIDs(_ id: String) {
        #expect(LocalModelPaths.isValidRepositoryID(id))
    }

    @Test(arguments: [
        "", "noslash", "/leading", "trailing/", "a/b/c", "../etc", "a/..", "a/../b", ".hidden/name",
        "owner/.hidden", "owner/na me", "owner/na\\me", "owner/na\0me", "own er/name", "owner/name?x=1",
    ])
    func rejectsInvalidRepositoryIDs(_ id: String) {
        #expect(!LocalModelPaths.isValidRepositoryID(id))
    }

    @Test func directoryNameFlattensTheSlash() {
        #expect(LocalModelPaths.directoryName(for: "mlx-community/Qwen3-4B-4bit") == "mlx-community--Qwen3-4B-4bit")
    }

    @Test func directoryForRejectsInvalidIDs() {
        let paths = LocalModelPaths(root: Self.root)
        #expect(throws: LocalModelError.invalidRepositoryID("../x")) { try paths.directory(for: "../x") }
    }

    @Test func directoryLivesDirectlyUnderRoot() throws {
        let paths = LocalModelPaths(root: Self.root)
        let directory = try paths.directory(for: "acme/tiny")
        #expect(directory.deletingLastPathComponent().standardizedFileURL == Self.root.standardizedFileURL)
        #expect(directory.lastPathComponent == "acme--tiny")
    }

    @Test func stagingSitsUnderRootSoTheFinalMoveIsAVolumeLocalRename() {
        let paths = LocalModelPaths(root: Self.root)
        #expect(paths.newStagingDirectory().path.hasPrefix(paths.root.path + "/.staging/"))
    }

    // MARK: - Untrusted file paths from a repository listing

    @Test(arguments: [
        "config.json", "model.safetensors", "onnx/model.json", "a/b/c/d.json", "tokenizer.model",
    ])
    func safeDestinationAcceptsOrdinaryPaths(_ path: String) throws {
        let base = URL(fileURLWithPath: "/tmp/staging/x", isDirectory: true)
        let destination = try LocalModelPaths.safeDestination(for: path, under: base)
        #expect(destination.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/"))
    }

    @Test(arguments: [
        "", "/etc/passwd", "../escape.json", "a/../../escape.json", "a/./b.json", "a//b.json", "a/..",
        "..", ".", "a\\b.json", "a/b\0.json", "trailing/",
    ])
    func safeDestinationRefusesEscapingPaths(_ path: String) {
        let base = URL(fileURLWithPath: "/tmp/staging/x", isDirectory: true)
        #expect(throws: LocalModelError.unsafeFilePath(path)) {
            try LocalModelPaths.safeDestination(for: path, under: base)
        }
    }

    // MARK: - Disk

    @Test func createDirectoriesMakesRootAndStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalModelPathsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.stagingRoot.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func defaultRootIsNamedModelsUnderApplicationSupport() throws {
        let root = try LocalModelPaths.defaultRoot()
        #expect(root.lastPathComponent == "Models")
        #expect(root.path.contains("Application Support"))
    }
}
