import Foundation
import Testing
@testable import AgentKit

/// A throwaway project folder.
final class TempProject: @unchecked Sendable {
    let root: URL

    init(files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files { try write(path, contents) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    var workspace: DiskAgentWorkspace { DiskAgentWorkspace(root: root) }
}

@Suite struct PathJailTests {
    @Test func resolvesRelativePathsInsideTheRoot() throws {
        let project = try TempProject(files: ["src/A.java": "x"])
        let jail = PathJail(root: project.root)
        #expect(jail.relativePath(of: try jail.resolve("src/A.java")) == "src/A.java")
        #expect(jail.relativePath(of: try jail.resolve("src/../src/A.java")) == "src/A.java")
        #expect(jail.relativePath(of: try jail.resolve(".")) == "")
        #expect(jail.relativePath(of: try jail.resolve(project.root.path + "/src/A.java")) == "src/A.java")
    }

    @Test func refusesDotDotEscapesAndOtherAbsolutePaths() throws {
        let project = try TempProject()
        let jail = PathJail(root: project.root)
        #expect(throws: AgentWorkspaceError.outsideProject("../etc/passwd")) { try jail.resolve("../etc/passwd") }
        #expect(throws: AgentWorkspaceError.outsideProject("/etc/passwd")) { try jail.resolve("/etc/passwd") }
        #expect(throws: AgentWorkspaceError.self) { try jail.resolve("a/../../b") }
    }

    @Test func aSiblingFolderWithTheSamePrefixDoesNotPass() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-\(UUID().uuidString)")
        let project = parent.appendingPathComponent("proj")
        let sibling = parent.appendingPathComponent("proj2")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let jail = PathJail(root: project)
        #expect(throws: AgentWorkspaceError.self) { try jail.resolve(sibling.path + "/secret.txt") }
        #expect(throws: AgentWorkspaceError.self) { try jail.resolve("../proj2/secret.txt") }
    }

    @Test func aSymlinkOutOfTheProjectIsRefused() throws {
        let outside = try TempProject(files: ["secret.txt": "s3cret"])
        let project = try TempProject()
        try FileManager.default.createSymbolicLink(
            at: project.root.appendingPathComponent("link"), withDestinationURL: outside.root)
        let jail = PathJail(root: project.root)
        #expect(throws: AgentWorkspaceError.self) { try jail.resolve("link/secret.txt") }
    }

    @Test func aNewFileUnderASymlinkedFolderIsCheckedThroughItsAncestor() throws {
        let outside = try TempProject()
        let project = try TempProject()
        try FileManager.default.createSymbolicLink(
            at: project.root.appendingPathComponent("link"), withDestinationURL: outside.root)
        let jail = PathJail(root: project.root)
        #expect(throws: AgentWorkspaceError.self) { try jail.resolve("link/new/file.txt") }
        // A new file in a real folder is fine even though it doesn't exist yet.
        #expect(jail.relativePath(of: try jail.resolve("fresh/dir/New.java")) == "fresh/dir/New.java")
    }

    @Test func aSymlinkInsideTheProjectIsFollowed() throws {
        let project = try TempProject(files: ["real/A.java": "x"])
        try FileManager.default.createSymbolicLink(
            at: project.root.appendingPathComponent("alias"), withDestinationURL: project.root.appendingPathComponent("real"))
        let jail = PathJail(root: project.root)
        #expect(jail.relativePath(of: try jail.resolve("alias/A.java")) == "real/A.java")
    }
}

@Suite struct GlobPatternTests {
    private func matches(_ pattern: String, _ path: String) throws -> Bool { try GlobPattern(pattern).matches(path) }

    @Test func aPatternWithoutASlashMatchesAtAnyDepth() throws {
        #expect(try matches("*.java", "A.java"))
        #expect(try matches("*.java", "src/main/A.java"))
        #expect(try !matches("*.java", "A.kt"))
        #expect(try matches("A?.java", "AB.java"))
    }

    @Test func starStaysInsideAFolderAndDoubleStarCrossesFolders() throws {
        #expect(try matches("src/*.java", "src/A.java"))
        #expect(try !matches("src/*.java", "src/main/A.java"))
        #expect(try matches("src/**/*.java", "src/main/deep/A.java"))
        #expect(try matches("src/**/A.java", "src/A.java"))
        #expect(try matches("**/test/**", "a/test/b/C.java"))
    }

    @Test func bracesAlternateAndDotsAreLiteral() throws {
        #expect(try matches("*.{java,kt}", "x/A.kt"))
        #expect(try !matches("*.{java,kt}", "x/A.js"))
        #expect(try !matches("A.java", "AxJava"))
    }

    @Test func unbalancedBracesAreRejected() {
        #expect(throws: AgentWorkspaceError.self) { try GlobPattern("*.{java") }
        #expect(throws: AgentWorkspaceError.self) { try GlobPattern("*.java}") }
    }
}

@Suite struct DiskAgentWorkspaceTests {
    @Test func readsTextAndRefusesBinaryAndDirectories() async throws {
        let project = try TempProject(files: ["A.txt": "hello"])
        try Data([0xff, 0xfe, 0x00]).write(to: project.root.appendingPathComponent("bin.dat"))
        let workspace = project.workspace
        #expect(try await workspace.readText(path: "A.txt") == "hello")
        await #expect(throws: AgentWorkspaceError.notText("bin.dat")) { try await workspace.readText(path: "bin.dat") }
        await #expect(throws: AgentWorkspaceError.notFound("nope")) { try await workspace.readText(path: "nope") }
        try FileManager.default.createDirectory(at: project.root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        await #expect(throws: AgentWorkspaceError.notAFile("dir")) { try await workspace.readText(path: "dir") }
        await #expect(throws: AgentWorkspaceError.self) { try await workspace.readText(path: "../outside") }
    }

    @Test func listingAndWalkingSkipIgnoredAndHiddenThings() async throws {
        let project = try TempProject(files: [
            "src/A.java": "a", "src/b/B.java": "b", "build/out.class": "x", ".git/config": "x",
            "node_modules/m/index.js": "x", ".env": "SECRET=1", "logo.png": "x", "README.md": "r",
        ])
        let workspace = project.workspace
        #expect(try await workspace.allFiles() == ["README.md", "src/A.java", "src/b/B.java"])
        let root = try await workspace.listDirectory(path: "")
        #expect(root.map(\.name) == ["src", "README.md"])
        #expect(root.first?.isDirectory == true)
    }

    @Test func searchFindsLinesFiltersByGlobAndPathAndTruncates() async throws {
        let project = try TempProject(files: [
            "src/A.java": "class A {\n  int count;\n}\n",
            "src/B.kt": "val count = 1\n",
            "docs/notes.md": "the count\n",
        ])
        let workspace = project.workspace
        let all = try await workspace.search(SearchQuery(pattern: "count"))
        #expect(all.matches.map(\.path) == ["docs/notes.md", "src/A.java", "src/B.kt"])
        #expect(all.matches.first { $0.path == "src/A.java" }?.line == 2)

        let javaOnly = try await workspace.search(SearchQuery(pattern: "count", fileGlob: "*.java"))
        #expect(javaOnly.matches.map(\.path) == ["src/A.java"])
        let underSrc = try await workspace.search(SearchQuery(pattern: "count", path: "src"))
        #expect(underSrc.matches.count == 2)

        let capped = try await workspace.search(SearchQuery(pattern: "count", maxResults: 1))
        #expect(capped.matches.count == 1 && capped.truncated)
    }

    @Test func searchSupportsLiteralAndCaseInsensitiveModes() async throws {
        let project = try TempProject(files: ["A.txt": "Foo(bar)\nfoo\n"])
        let literal = try await project.workspace.search(SearchQuery(pattern: "Foo(bar)", isRegex: false))
        #expect(literal.matches.map(\.line) == [1])
        let loose = try await project.workspace.search(SearchQuery(pattern: "FOO", caseSensitive: false))
        #expect(loose.matches.map(\.line) == [1, 2])
        await #expect(throws: AgentWorkspaceError.invalidPattern("(")) {
            _ = try await project.workspace.search(SearchQuery(pattern: "("))
        }
    }
}

@Suite struct UnsavedBufferTests {
    @Test func readsAndSearchesSeeUnsavedEditsInsteadOfDisk() async throws {
        let project = try TempProject(files: ["A.java": "int old;\n", "B.java": "int other;\n"])
        // Keyed by the unresolved temp path, as an app would hand it over.
        let path = project.root.appendingPathComponent("A.java").path
        let workspace = DiskAgentWorkspace(root: project.root, unsavedBuffers: { [path: "int fresh;\n"] })

        #expect(try await workspace.readText(path: "A.java") == "int fresh;\n")
        #expect(try await workspace.readText(path: "B.java") == "int other;\n")

        let fresh = try await workspace.search(SearchQuery(pattern: "fresh"))
        #expect(fresh.matches.map(\.path) == ["A.java"])
        let old = try await workspace.search(SearchQuery(pattern: "old"))
        #expect(old.matches.isEmpty, "the stale disk text must not be searched")
    }
}
