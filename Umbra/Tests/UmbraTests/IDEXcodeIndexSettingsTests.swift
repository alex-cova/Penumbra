import XCTest
@testable import Umbra

/// `xcodebuild -showBuildSettingsForIndex -json` becoming the compilation database SourceKit-LSP reads.
final class IDEXcodeIndexSettingsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/dev/App")
    private let rsp = URL(fileURLWithPath: "/Users/dev/Library/Caches/com.umbra.editor/sourcekit/abc")

    /// What `xcodebuild` prints: every file of a module carries the module's whole argument list.
    private func settings(_ targets: [String: [String: [String: Any]]]) -> Data {
        try! JSONSerialization.data(withJSONObject: targets)
    }

    private func module(_ name: String, files: [String], extra: [String] = []) -> [String: [String: Any]] {
        let arguments = ["-module-name", name, "-O"] + files + ["-sdk", "/SDK", "-target", "arm64-apple-macos14.0"] + extra
        return Dictionary(uniqueKeysWithValues: files.map {
            ($0, ["swiftASTCommandArguments": arguments, "swiftASTModuleName": name, "LanguageDialect": "Xcode.SourceCodeLanguage.Swift"])
        })
    }

    private func commands(_ database: IDEXcodeIndexSettings.Database) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: database.compileCommands) as? [[String: Any]])
    }

    func testEachFileGetsAnEntryThatNamesTheModulesResponseFile() throws {
        let files = ["/Users/dev/App/Sources/A.swift", "/Users/dev/App/Sources/B.swift"]
        let database = try IDEXcodeIndexSettings.database(
            from: settings(["App": module("App", files: files)]), projectRoot: root, responseFileDirectory: rsp
        )
        XCTAssertEqual(database.fileCount, 2)
        XCTAssertEqual(database.moduleCount, 1)
        XCTAssertEqual(database.responseFiles.count, 1, "both files share one argument list, so one response file")
        let name = try XCTUnwrap(database.responseFiles.keys.first)
        XCTAssertTrue(name.hasPrefix("App-") && name.hasSuffix(".rsp"), name)

        let entries = try commands(database)
        XCTAssertEqual(entries.compactMap { $0["file"] as? String }, files)
        for entry in entries {
            XCTAssertEqual(entry["directory"] as? String, "/Users/dev/App")
            XCTAssertEqual(entry["arguments"] as? [String], ["swiftc", "@" + rsp.appendingPathComponent(name).path])
        }
    }

    func testTheResponseFileHoldsOneQuotedArgumentPerLine() throws {
        let files = ["/Users/dev/App/Sources/A.swift"]
        let database = try IDEXcodeIndexSettings.database(
            from: settings(["App": module("App", files: files, extra: ["-Xcc", "-DNAME=\"a b\"", "-I", "/path with space"])]),
            projectRoot: root, responseFileDirectory: rsp
        )
        let contents = try XCTUnwrap(database.responseFiles.values.first)
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "\"-module-name\"")
        XCTAssertTrue(lines.contains("\"-DNAME=\\\"a b\\\"\""), "a quote inside an argument is escaped: \(lines)")
        XCTAssertTrue(lines.contains("\"/path with space\""), "a space stays inside the quotes")
    }

    func testTwoModulesGetTwoResponseFilesAndTheSameArgumentsAlwaysTheSameName() throws {
        let one = module("One", files: ["/Users/dev/App/One/A.swift"])
        let two = module("Two", files: ["/Users/dev/App/Two/B.swift"])
        let first = try IDEXcodeIndexSettings.database(from: settings(["One": one, "Two": two]), projectRoot: root, responseFileDirectory: rsp)
        let second = try IDEXcodeIndexSettings.database(from: settings(["Two": two, "One": one]), projectRoot: root, responseFileDirectory: rsp)
        XCTAssertEqual(first.responseFiles.count, 2)
        XCTAssertEqual(first.moduleCount, 2)
        XCTAssertEqual(Set(first.responseFiles.keys), Set(second.responseFiles.keys), "names come from the arguments, not the order")
        XCTAssertEqual(first.compileCommands, second.compileCommands, "the database does not depend on dictionary order")
    }

    func testAFileInTwoTargetsBelongsToTheFirstOneInTheOrderGiven() throws {
        let shared = "/Users/dev/App/Shared.swift"
        let app = module("App", files: [shared])
        let tests = module("AppTests", files: [shared])
        let database = try IDEXcodeIndexSettings.database(
            from: settings(["AppTests": tests, "App": app]), projectRoot: root, responseFileDirectory: rsp, targetOrder: ["App", "AppTests"]
        )
        let entries = try commands(database)
        XCTAssertEqual(entries.count, 1)
        let arguments = try XCTUnwrap(entries.first?["arguments"] as? [String])
        XCTAssertTrue(arguments[1].contains("App-"), "the app's arguments, not the tests': \(arguments)")
        XCTAssertFalse(arguments[1].contains("AppTests-"))
    }

    func testEveryWayTheFolderCanBeSpelledGetsAnEntry() throws {
        // `/tmp` is a symlink to `/private/tmp`: the server finds a file by the spelling the editor opens it under.
        let tmp = URL(fileURLWithPath: "/tmp/xcode-index-spellings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try IDEXcodeIndexSettings.database(
            from: settings(["App": module("App", files: [tmp.path + "/Sources/A.swift"])]),
            projectRoot: tmp, responseFileDirectory: rsp
        )
        let files = try commands(database).compactMap { $0["file"] as? String }
        XCTAssertEqual(Set(files), [
            "/tmp/\(tmp.lastPathComponent)/Sources/A.swift", "/private/tmp/\(tmp.lastPathComponent)/Sources/A.swift",
        ])
        XCTAssertEqual(database.fileCount, 1, "two spellings, one file")
    }

    func testAFileOutsideTheProjectFolderKeepsItsOwnSpelling() throws {
        let database = try IDEXcodeIndexSettings.database(
            from: settings(["App": module("App", files: ["/Users/dev/Other/Dep.swift"])]), projectRoot: root, responseFileDirectory: rsp
        )
        XCTAssertEqual(try commands(database).compactMap { $0["file"] as? String }, ["/Users/dev/Other/Dep.swift"])
    }

    func testEntriesWithoutSwiftArgumentsAreSkippedAndAProjectWithNoneSaysSo() throws {
        let mixed: [String: [String: [String: Any]]] = [
            "App": [
                "/Users/dev/App/main.m": ["clangASTCommandArguments": ["-x", "objective-c"]],
                "/Users/dev/App/Empty.swift": ["swiftASTCommandArguments": [String]()],
            ],
        ]
        XCTAssertThrowsError(try IDEXcodeIndexSettings.database(from: settings(mixed), projectRoot: root, responseFileDirectory: rsp)) {
            XCTAssertEqual($0 as? IDEXcodeIndexSettings.Failure, .noSwiftFiles)
        }
        XCTAssertThrowsError(try IDEXcodeIndexSettings.database(from: Data("not json".utf8), projectRoot: root, responseFileDirectory: rsp)) {
            XCTAssertEqual($0 as? IDEXcodeIndexSettings.Failure, .notIndexSettings)
        }
        XCTAssertThrowsError(try IDEXcodeIndexSettings.database(from: Data("[1, 2]".utf8), projectRoot: root, responseFileDirectory: rsp)) {
            XCTAssertEqual($0 as? IDEXcodeIndexSettings.Failure, .notIndexSettings)
        }
    }

    func testTheRelativePathClimbsOutOfTheProjectToTheCache() {
        let from = URL(fileURLWithPath: "/Users/dev/App")
        XCTAssertEqual(
            IDEXcodeIndexSettings.relativePath(from: from, to: URL(fileURLWithPath: "/Users/dev/Library/Caches/x")),
            "../Library/Caches/x"
        )
        XCTAssertEqual(IDEXcodeIndexSettings.relativePath(from: from, to: URL(fileURLWithPath: "/Users/dev/App/.cache")), ".cache")
        XCTAssertEqual(
            IDEXcodeIndexSettings.relativePath(from: URL(fileURLWithPath: "/a/b/c/d"), to: URL(fileURLWithPath: "/x/y")),
            "../../../../x/y"
        )
        XCTAssertEqual(IDEXcodeIndexSettings.relativePath(from: from, to: from), "")
    }
}
