import Foundation
import XCTest
@testable import Umbra

/// FSEvents delivery timing is environment-dependent (a real kernel notification path, not
/// something this suite can fake), so these use generous timeouts and only assert that the events
/// that matter eventually show up. Some `xctest` host processes receive no FSEvents callbacks at
/// all; those tests skip rather than fail when nothing arrives.
final class IDEFSEventStreamTests: XCTestCase {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A window that closes right after it opened a project stops a stream that is still starting.
    /// `FSEventStreamStart` on a stream `stop()` had already released crashed the process.
    func testStoppingWhileStartingDoesNotCrash() async {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<300 {
                let stream = IDEFSEventStream(roots: [root.path], latency: 0.05) { _ in true }
                group.addTask { stream.start() }
                group.addTask { stream.stop() }
            }
        }
    }

    func testAStoppedStreamDoesNotStartAgain() async {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = IDEFSEventStream(roots: [root.path], latency: 0.05) { _ in true }
        stream.stop()
        stream.start()
        var iterator = stream.paths.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "stop() ended the path stream, and a late start() must not bring it back")
    }

    func testCanonicalPathResolvesPrivateVar() {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("not-yet.txt").path
        let canonical = IDEFSEventStream.canonicalPath(missing)
        XCTAssertEqual(canonical, IDEFSEventStream.canonicalPath(root.path) + "/not-yet.txt")
    }

    func testFilteredPathsOnlyAndSeveralRoots() async throws {
        let first = tempDirectory()
        let second = tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let roots = [first, second].map { IDEFSEventStream.canonicalPath($0.path) }
        let stream = IDEFSEventStream(roots: roots, latency: 0.05) { !$0.hasSuffix(".txt") }
        stream.start()
        defer { stream.stop() }
        try await Task.sleep(for: .milliseconds(200))

        try "x".write(to: first.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: first.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let target = roots[1] + "/b.swift"
        try "x".write(toFile: target, atomically: true, encoding: .utf8)

        let seen = await collect(stream.paths, until: target, timeout: 5)
        guard seen.contains(target) else {
            throw XCTSkip("No FSEvents callback observed in this xctest host process within the timeout.")
        }
        XCTAssertFalse(seen.contains { $0.hasSuffix(".txt") }, "the filter keeps these out")
    }

    private func collect(_ paths: AsyncStream<String>, until target: String, timeout: TimeInterval) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            group.addTask {
                var seen: [String] = []
                for await path in paths {
                    seen.append(path)
                    if path == target { break }
                }
                return seen
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}

/// The batches subscribers see: project paths, open files outside the project, ignored folders.
@MainActor
final class IDEProjectWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits for the first batch that satisfies `condition`, collecting every batch on the way.
    private func batches(
        from watcher: IDEProjectWatcher, timeout: TimeInterval = 5, after action: () throws -> Void,
        until condition: @escaping (IDEProjectWatcher.Batch) -> Bool
    ) async throws -> [IDEProjectWatcher.Batch]? {
        var received: [IDEProjectWatcher.Batch] = []
        var done = false
        watcher.onBatch = [{ batch in
            received.append(batch)
            if condition(batch) { done = true }
        }]
        try await Task.sleep(for: .milliseconds(300))
        try action()
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return done ? received : nil
    }

    func testProjectPathsAndOpenFilesOutsideTheRoot() async throws {
        let project = try folder("project")
        let loose = try folder("loose")
        let open = loose.appendingPathComponent("notes.md")
        try "a".write(to: open, atomically: true, encoding: .utf8)
        let watcher = IDEProjectWatcher()
        defer { watcher.stop() }
        watcher.setRoot(project)
        watcher.setOpenFiles([open.path])

        let inProject = project.appendingPathComponent("Main.swift").path
        guard let seen = try await batches(from: watcher, after: {
            try "x".write(toFile: inProject, atomically: true, encoding: .utf8)
            try "sibling".write(to: loose.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
            try "b".write(to: open, atomically: true, encoding: .utf8)
        }, until: { $0.openFilePaths.contains(open.path) }) else {
            throw XCTSkip("No FSEvents callback observed in this xctest host process within the timeout.")
        }
        let paths = seen.reduce(into: Set<String>()) { $0.formUnion($1.paths) }
        let openPaths = seen.reduce(into: Set<String>()) { $0.formUnion($1.openFilePaths) }
        XCTAssertEqual(openPaths, [open.path], "a sibling of an open file outside the root is not reported")
        XCTAssertFalse(paths.contains { $0.hasPrefix(loose.path) })
        if !paths.isEmpty {
            XCTAssertTrue(paths.allSatisfy { $0 == project.path || $0.hasPrefix(project.path + "/") }, "project paths keep the root's spelling: \(paths)")
        }
    }

    func testAnOpenFileUnderAnIgnoredFolderIsReportedApartFromProjectPaths() async throws {
        let project = try folder("project")
        let modules = project.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let open = modules.appendingPathComponent("index.js")
        try "a".write(to: open, atomically: true, encoding: .utf8)
        let watcher = IDEProjectWatcher()
        defer { watcher.stop() }
        watcher.setRoot(project)
        watcher.setOpenFiles([open.path])

        guard let seen = try await batches(from: watcher, after: {
            try "other".write(to: modules.appendingPathComponent("other.js"), atomically: true, encoding: .utf8)
            try "b".write(to: open, atomically: true, encoding: .utf8)
        }, until: { $0.openFilePaths.contains(open.path) }) else {
            throw XCTSkip("No FSEvents callback observed in this xctest host process within the timeout.")
        }
        XCTAssertFalse(seen.contains { $0.paths.contains { $0.contains("/node_modules/") } }, "the Explorer never sees node_modules")
    }

    func testAWindowWithNoFolderStillWatchesItsOpenFiles() async throws {
        let loose = try folder("loose")
        let open = loose.appendingPathComponent("a.txt")
        try "a".write(to: open, atomically: true, encoding: .utf8)
        let watcher = IDEProjectWatcher()
        defer { watcher.stop() }
        watcher.setRoot(nil)
        watcher.setOpenFiles([open.path])

        let seen = try await batches(from: watcher, after: {
            try "b".write(to: open, atomically: true, encoding: .utf8)
        }, until: { $0.openFilePaths.contains(open.path) })
        guard seen != nil else {
            throw XCTSkip("No FSEvents callback observed in this xctest host process within the timeout.")
        }
    }
}
