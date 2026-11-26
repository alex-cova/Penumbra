import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

final class IDEBlameSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "blame-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSettingsRoundTripThroughDefaults() {
        let store = defaults()
        XCTAssertEqual(IDEBlameSettings.load(from: store), IDEBlameSettings())
        var settings = IDEBlameSettings()
        settings.authorStyle = .initials
        settings.coloring = .author
        settings.ignoresWhitespace = true
        settings.showsHash = true
        settings.save(to: store)
        XCTAssertEqual(IDEBlameSettings.load(from: store), settings)
    }

    func testAnOlderOrHandEditedValueFallsBackToDefaults() {
        let store = defaults()
        store.set(Data(#"{"coloring":"author","authorStyle":"nonsense"}"#.utf8), forKey: IDEBlameSettings.defaultsKey)
        // A value that does not decode is replaced by the defaults, not half applied.
        XCTAssertEqual(IDEBlameSettings.load(from: store), IDEBlameSettings())
        store.set(Data(#"{"coloring":"author"}"#.utf8), forKey: IDEBlameSettings.defaultsKey)
        let partial = IDEBlameSettings.load(from: store)
        XCTAssertEqual(partial.coloring, .author)
        XCTAssertTrue(partial.showsAuthor)
        XCTAssertEqual(partial.authorStyle, .full)
    }

    func testOptionsCarryTheFlagsAndTheHiddenRevisions() {
        var settings = IDEBlameSettings()
        XCTAssertEqual(settings.options(), .default)
        settings.ignoresWhitespace = true
        settings.detectsMovesAcrossFiles = true
        let hash = String(repeating: "d", count: 40)
        XCTAssertEqual(settings.options(hiding: [hash]).arguments(), ["-w", "-C", "--ignore-rev", hash])
        XCTAssertEqual(settings.gitFlags, [true, false, true])
        // View settings never change what git is asked.
        var viewOnly = settings
        viewOnly.coloring = .none
        viewOnly.showsHash = true
        XCTAssertEqual(viewOnly.gitFlags, settings.gitFlags)
    }
}

final class IDEGitRevisionFilesTests: XCTestCase {
    private var cache: URL!
    private let commitHash = String(repeating: "a", count: 40)

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("revisions-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
    }

    func testASnapshotNamesWhereItCameFrom() throws {
        let url = try XCTUnwrap(IDEGitRevisionFiles.write(
            Data("old\n".utf8), repositoryRoot: "/work/project", hash: commitHash, relativePath: "src/main/Foo.java", cacheRoot: cache))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
        XCTAssertEqual(url.lastPathComponent, "Foo.java")
        XCTAssertTrue(IDEGitRevisionFiles.isSnapshot(url, cacheRoot: cache))
        XCTAssertEqual(IDEGitRevisionFiles.source(for: url, cacheRoot: cache),
                       .init(repositoryRoot: "/work/project", hash: commitHash, relativePath: "src/main/Foo.java"))
    }

    func testTheSameCommitIsWrittenOnceAndTwoRepositoriesDoNotShareACopy() throws {
        let first = try XCTUnwrap(IDEGitRevisionFiles.write(Data("one".utf8), repositoryRoot: "/a", hash: commitHash, relativePath: "f.txt", cacheRoot: cache))
        // A commit never changes: an existing copy is kept.
        let again = try XCTUnwrap(IDEGitRevisionFiles.write(Data("different".utf8), repositoryRoot: "/a", hash: commitHash, relativePath: "f.txt", cacheRoot: cache))
        XCTAssertEqual(first, again)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        let other = try XCTUnwrap(IDEGitRevisionFiles.write(Data("two".utf8), repositoryRoot: "/b", hash: commitHash, relativePath: "f.txt", cacheRoot: cache))
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(IDEGitRevisionFiles.source(for: other, cacheRoot: cache)?.repositoryRoot, "/b")
    }

    func testAnUnsafeHashOrPathIsRefused() {
        XCTAssertNil(IDEGitRevisionFiles.snapshotURL(repositoryRoot: "/a", hash: "--contents", relativePath: "f", cacheRoot: cache))
        XCTAssertNil(IDEGitRevisionFiles.snapshotURL(repositoryRoot: "/a", hash: commitHash, relativePath: "", cacheRoot: cache))
        let url = IDEGitRevisionFiles.snapshotURL(repositoryRoot: "/a", hash: commitHash, relativePath: "../../etc/./passwd", cacheRoot: cache)
        XCTAssertEqual(url?.path.hasPrefix(cache.path + "/"), true)
        XCTAssertEqual(url?.lastPathComponent, "passwd")
        XCTAssertFalse(url?.pathComponents.contains("..") ?? true)
    }

    func testOtherFilesAreNotSnapshots() throws {
        XCTAssertFalse(IDEGitRevisionFiles.isSnapshot(URL(fileURLWithPath: "/work/project/Foo.java"), cacheRoot: cache))
        // A file under the cache that this cache did not write (no recorded root) is not one either.
        let stray = cache.appendingPathComponent("abc/\(commitHash)/Foo.java")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: stray)
        XCTAssertFalse(IDEGitRevisionFiles.isSnapshot(stray, cacheRoot: cache))
    }
}
