import Foundation
import Testing
@testable import LocalModelStore

struct LocalModelCatalogTests {
    private func makeRoot() throws -> LocalModelPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalModelCatalogTests-\(UUID().uuidString)")
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        return paths
    }

    @discardableResult
    private func install(_ id: String, bytes: Int64 = 100, at date: Date = .now, in paths: LocalModelPaths) throws -> URL {
        let directory = try paths.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LocalModelCatalog.writeManifest(
            LocalModelManifest(repositoryID: id, revision: "abc", downloadedAt: date, totalBytes: bytes), into: directory)
        return directory
    }

    @Test func listsOnlyFoldersWithAManifest() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try install("acme/one", in: paths)
        try FileManager.default.createDirectory(
            at: paths.root.appendingPathComponent("acme--half-downloaded"), withIntermediateDirectories: true)

        let models = LocalModelCatalog(paths: paths).installed()
        #expect(models.map(\.id) == ["acme/one"])
    }

    @Test func ignoresStagingEvenWhenItLooksComplete() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let staged = paths.newStagingDirectory()
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try LocalModelCatalog.writeManifest(
            LocalModelManifest(repositoryID: "acme/staged", revision: "x", downloadedAt: .now, totalBytes: 1), into: staged)

        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
    }

    @Test func listsNewestFirst() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try install("acme/old", at: Date(timeIntervalSince1970: 1_000), in: paths)
        try install("acme/new", at: Date(timeIntervalSince1970: 9_000), in: paths)

        #expect(LocalModelCatalog(paths: paths).installed().map(\.id) == ["acme/new", "acme/old"])
    }

    @Test func skipsAManifestWhoseRepositoryIDIsNotValid() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let directory = paths.root.appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LocalModelCatalog.writeManifest(
            LocalModelManifest(repositoryID: "../../etc", revision: "x", downloadedAt: .now, totalBytes: 1), into: directory)

        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
    }

    @Test func skipsACorruptManifest() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let directory = paths.root.appendingPathComponent("acme--corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: directory.appendingPathComponent(LocalModelPaths.manifestFileName))

        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
    }

    @Test func totalBytesSumsInstalledModels() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try install("acme/a", bytes: 300, in: paths)
        try install("acme/b", bytes: 200, in: paths)

        #expect(LocalModelCatalog(paths: paths).totalBytes() == 500)
    }

    @Test func emptyOrMissingRootListsNothing() {
        let missing = LocalModelPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)"))
        #expect(LocalModelCatalog(paths: missing).installed().isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesTheModelFolder() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let directory = try install("acme/gone", in: paths)
        let catalog = LocalModelCatalog(paths: paths)

        try catalog.delete(try #require(catalog.installed().first))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// `delete` recursively removes a directory, so it must refuse anything outside the models root.
    @Test func deleteRefusesAFolderOutsideTheRoot() throws {
        let paths = try makeRoot()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: paths.root)
            try? FileManager.default.removeItem(at: outside)
        }
        let forged = InstalledLocalModel(
            manifest: LocalModelManifest(repositoryID: "acme/x", revision: "x", downloadedAt: .now, totalBytes: 1),
            directory: outside)

        #expect(throws: LocalModelError.self) { try LocalModelCatalog(paths: paths).delete(forged) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func deleteRefusesTheRootItself() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let forged = InstalledLocalModel(
            manifest: LocalModelManifest(repositoryID: "acme/x", revision: "x", downloadedAt: .now, totalBytes: 1),
            directory: paths.root)

        #expect(throws: LocalModelError.self) { try LocalModelCatalog(paths: paths).delete(forged) }
        #expect(FileManager.default.fileExists(atPath: paths.root.path))
    }

    // MARK: - Staging

    @Test func clearStagingRemovesLeftoversButKeepsInstalledModels() throws {
        let paths = try makeRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try install("acme/keep", in: paths)
        let leftover = paths.newStagingDirectory()
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let catalog = LocalModelCatalog(paths: paths)
        catalog.clearStaging()

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(catalog.installed().map(\.id) == ["acme/keep"])
    }
}
