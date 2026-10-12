import CryptoKit
import XCTest
@testable import JavaIntelligence

final class GradleProjectModelCacheTests: XCTestCase {
    func testStoreAndLoadRoundTrip() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        try "root project".write(
            to: projectRoot.appendingPathComponent("settings.gradle"),
            atomically: true,
            encoding: .utf8
        )
        try "plugins { id 'java' }".write(
            to: projectRoot.appendingPathComponent("build.gradle"),
            atomically: true,
            encoding: .utf8
        )

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)

        XCTAssertNil(cache.loadIfValid(projectRoot: projectRoot))
        cache.store(projectRoot: projectRoot, model: model)

        let loaded = try XCTUnwrap(cache.loadIfValid(projectRoot: projectRoot))
        XCTAssertEqual(loaded.formatVersion, model.formatVersion)
        XCTAssertEqual(loaded.subprojects.map(\.path), model.subprojects.map(\.path))
        XCTAssertEqual(loaded.classpathJars, model.classpathJars)
    }

    func testLoadReturnsNilWhenBuildFileChanges() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let buildFile = projectRoot.appendingPathComponent("build.gradle")
        try "v1".write(to: buildFile, atomically: true, encoding: .utf8)

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)
        cache.store(projectRoot: projectRoot, model: model)
        XCTAssertNotNil(cache.loadIfValid(projectRoot: projectRoot))

        try "v2".write(to: buildFile, atomically: true, encoding: .utf8)
        XCTAssertNil(cache.loadIfValid(projectRoot: projectRoot))
    }

    func testInvalidateRemovesCachedModel() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        try "root project".write(
            to: projectRoot.appendingPathComponent("settings.gradle"),
            atomically: true,
            encoding: .utf8
        )

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)
        cache.store(projectRoot: projectRoot, model: model)
        XCTAssertNotNil(cache.loadIfValid(projectRoot: projectRoot))

        cache.invalidate(projectRoot: projectRoot)
        XCTAssertNil(cache.loadIfValid(projectRoot: projectRoot))
    }

    func testLoadReturnsNilWhenScriptFormatVersionChanges() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        try "root project".write(
            to: projectRoot.appendingPathComponent("settings.gradle"),
            atomically: true,
            encoding: .utf8
        )

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)
        cache.store(projectRoot: projectRoot, model: model)

        let directory = cacheRoot.appendingPathComponent(
            sha256(projectRoot.standardizedFileURL.path),
            isDirectory: true
        )
        let metaURL = directory.appendingPathComponent("meta.json")
        var meta = try JSONDecoder().decode(TestMetadata.self, from: Data(contentsOf: metaURL))
        meta.fingerprint = GradleBuildFingerprint(
            scriptFormatVersion: GradleProjectModelScript.formatVersion - 1,
            files: meta.fingerprint.files
        )
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)

        XCTAssertNil(cache.loadIfValid(projectRoot: projectRoot))
    }

    func testOldFormatCacheIsIgnoredWithoutCrashing() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try "v1".write(to: projectRoot.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)
        cache.store(projectRoot: projectRoot, model: model)
        XCTAssertNotNil(cache.loadIfValid(projectRoot: projectRoot))

        // Rewrite meta.json the way an older build wrote it: no `cacheFormat` key.
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil).first)
        let metaURL = directory.appendingPathComponent("meta.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "cacheFormat"))
        try JSONSerialization.data(withJSONObject: object).write(to: metaURL)

        XCTAssertNil(cache.loadIfValid(projectRoot: projectRoot))
        XCTAssertNil(cache.changedBuildFiles(projectRoot: projectRoot))

        cache.store(projectRoot: projectRoot, model: model)
        XCTAssertNotNil(cache.loadIfValid(projectRoot: projectRoot))
    }

    func testChangedBuildFilesNamesModifiedAddedAndRemovedFiles() throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let projectRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let build = projectRoot.appendingPathComponent("build.gradle")
        let settings = projectRoot.appendingPathComponent("settings.gradle")
        try "v1".write(to: build, atomically: true, encoding: .utf8)
        try "s".write(to: settings, atomically: true, encoding: .utf8)

        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let cache = GradleProjectModelCache(cacheRoot: cacheRoot)
        cache.store(projectRoot: projectRoot, model: model)
        XCTAssertEqual(cache.changedBuildFiles(projectRoot: projectRoot), [])

        try "version 2, longer".write(to: build, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: settings)
        try "a=b".write(to: projectRoot.appendingPathComponent("gradle.properties"), atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.changedBuildFiles(projectRoot: projectRoot), ["build.gradle", "gradle.properties", "settings.gradle"])
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct TestMetadata: Codable {
    var fingerprint: GradleBuildFingerprint
    var cachedAt: Date
    var cacheFormat: Int?
}
