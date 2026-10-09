import XCTest
@testable import JavaIntelligence

final class JavaProcessLaunchTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/jdk/21")
    private let project = URL(fileURLWithPath: "/proj")
    private let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/dev", "MODE": "base"]

    private func main(_ adjust: (inout JavaRunConfiguration) -> Void = { _ in }) -> JavaRunConfiguration {
        var configuration = JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/proj/app/src/Main.java"))
        adjust(&configuration)
        return configuration
    }

    private func launch(
        _ configuration: JavaRunConfiguration, classpath: [URL]? = [URL(fileURLWithPath: "/proj/app/classes"), URL(fileURLWithPath: "/lib/a.jar")],
        version: Int? = 21, projectRoot: URL? = nil, directory: URL? = nil, usesNewLaunchProtocol: Bool = false
    ) -> JavaProcessLaunch? {
        JavaLaunchCommand.makeProcessLaunch(
            configuration: configuration, javaHome: home, runtimeClasspath: classpath,
            projectRoot: projectRoot ?? project, jdkFeatureVersion: version,
            usesNewLaunchProtocol: usesNewLaunchProtocol, baseEnvironment: base,
            argFileDirectory: directory ?? FileManager.default.temporaryDirectory
        )
    }

    // MARK: - Splitting

    func testSplitHandlesQuotesAndEscapes() {
        XCTAssertEqual(JavaCommandLine.split(""), [])
        XCTAssertEqual(JavaCommandLine.split("   "), [])
        XCTAssertEqual(JavaCommandLine.split("a  b\tc\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(JavaCommandLine.split(#"one "two words" 'three words'"#), ["one", "two words", "three words"])
        XCTAssertEqual(JavaCommandLine.split(#"-Dname="a b" x"#), ["-Dname=a b", "x"])
        XCTAssertEqual(JavaCommandLine.split(#""say \"hi\"" 'it'\''s'"#), [#"say "hi""#, "it's"], "the shell idiom for a quote inside quotes")
        XCTAssertEqual(JavaCommandLine.split(#"a\ b"#), ["a b"])
        XCTAssertEqual(JavaCommandLine.split(#"'\n' "\n""#), [#"\n"#, #"\n"#], "a backslash before anything but a quote or backslash stays")
        XCTAssertEqual(JavaCommandLine.split(#"x "" y"#), ["x", "", "y"], "an empty quoted argument is kept")
        XCTAssertEqual(JavaCommandLine.split(#"open "never closed"#), ["open", "never closed"])
    }

    // MARK: - Process launch

    func testAClasspathLaunchIsAProgramAndArguments() throws {
        let launch = try XCTUnwrap(launch(main {
            $0.vmArguments = "-Xmx1g -Dgreeting=\"hello there\""
            $0.programArguments = "--port 80 'two words'"
        }))
        XCTAssertEqual(launch.executable.path, "/jdk/21/bin/java")
        XCTAssertEqual(launch.arguments, [
            "-Xmx1g", "-Dgreeting=hello there", "-cp", "/proj/app/classes:/lib/a.jar", "app.Main", "--port", "80", "two words"
        ])
        XCTAssertEqual(launch.workingDirectory.path, "/proj")
        XCTAssertTrue(launch.temporaryFiles.isEmpty)
        XCTAssertNil(launch.redirectInput)
    }

    func testTheEnvironmentLayersJdkThenTheConfigurationsOwn() throws {
        let launch = try XCTUnwrap(launch(main {
            $0.environment = ["MODE": "dev", "JAVA_OPTS": "-x", "bad name": "dropped", "1X": "dropped"]
        }))
        XCTAssertEqual(launch.environment["JAVA_HOME"], "/jdk/21")
        XCTAssertEqual(launch.environment["PATH"], "/jdk/21/bin:/usr/bin:/bin")
        XCTAssertEqual(launch.environment["HOME"], "/Users/dev", "the rest is inherited")
        XCTAssertEqual(launch.environment["MODE"], "dev", "the configuration wins over the base")
        XCTAssertEqual(launch.environment["JAVA_OPTS"], "-x")
        XCTAssertNil(launch.environment["bad name"])
        XCTAssertNil(launch.environment["1X"])
    }

    func testAConfigurationMayOverrideJavaHome() throws {
        let launch = try XCTUnwrap(launch(main { $0.environment = ["JAVA_HOME": "/other"] }))
        XCTAssertEqual(launch.environment["JAVA_HOME"], "/other")
    }

    func testWorkingDirectoryFallsBackFromTheConfigurationToTheProjectToTheFile() throws {
        XCTAssertEqual(try XCTUnwrap(launch(main { $0.workingDirectory = "/work" })).workingDirectory.path, "/work")
        XCTAssertEqual(try XCTUnwrap(launch(main { $0.workingDirectory = "" })).workingDirectory.path, "/proj")
        let single = JavaRunConfiguration(target: .singleFile(path: "/loose/Hello.java"), programArguments: "a b")
        let noProject = JavaLaunchCommand.makeProcessLaunch(
            configuration: single, javaHome: home, runtimeClasspath: nil, projectRoot: nil, baseEnvironment: base
        )
        XCTAssertEqual(noProject?.workingDirectory.path, "/loose")
        XCTAssertEqual(noProject?.arguments, ["/loose/Hello.java", "a", "b"])
    }

    func testRedirectedInputIsPartOfTheLaunch() throws {
        let launch = try XCTUnwrap(launch(main { $0.redirectInputPath = "/data/in.txt" }))
        XCTAssertEqual(launch.redirectInput?.path, "/data/in.txt")
        XCTAssertTrue(launch.displayCommand.hasSuffix("< /data/in.txt"), launch.displayCommand)
    }

    func testOtherTargetsAndBadInputGiveNoLaunch() {
        XCTAssertNil(launch(JavaRunConfiguration(target: .gradleRun(projectPath: ":"))))
        XCTAssertNil(launch(JavaRunConfiguration(target: .gradleTest(taskPath: ":test", filters: [], sourceFile: nil))))
        XCTAssertNil(launch(main(), classpath: nil))
        XCTAssertNil(launch(main(), classpath: []))
        XCTAssertNil(launch(JavaRunConfiguration(target: .classpathMain(className: "a; rm -rf ~", sourceFile: "/x/A.java"))))
    }

    func testTheDisplayCommandQuotesWhatNeedsIt() throws {
        let launch = try XCTUnwrap(launch(main {
            $0.environment = ["MODE": "two words"]
            $0.programArguments = "'it''s here'"
        }, classpath: [URL(fileURLWithPath: "/My Proj/classes")]))
        XCTAssertEqual(
            launch.displayCommand,
            "cd /proj && MODE='two words' /jdk/21/bin/java -cp '/My Proj/classes' app.Main 'its here'"
        )
    }

    // MARK: - @argfile

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnArgFileCarriesTheClasspathWhenAsked() throws {
        let directory = try scratch()
        let launch = try XCTUnwrap(launch(
            main { $0.shortenCommandLine = .argFile; $0.vmArguments = "-ea" },
            classpath: [URL(fileURLWithPath: "/My Proj/classes"), URL(fileURLWithPath: "/lib/it\"s.jar")], directory: directory
        ))
        let file = try XCTUnwrap(launch.temporaryFiles.first)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(launch.arguments, ["-ea", "@\(file.path)", "app.Main"])
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, "-cp \"/My Proj/classes:/lib/it\\\"s.jar\"\n")
    }

    func testAutoUsesAnArgFileOnlyForALongClasspathOnJava9OrLater() throws {
        let directory = try scratch()
        let long = (0..<2_000).map { URL(fileURLWithPath: "/repo/libs/some-library-\($0).jar") }
        let short = [URL(fileURLWithPath: "/a.jar")]

        XCTAssertEqual(launch(main(), classpath: long, directory: directory)?.temporaryFiles.count, 1)
        XCTAssertEqual(launch(main(), classpath: short, directory: directory)?.temporaryFiles.count, 0)
        XCTAssertEqual(launch(main(), classpath: long, version: 8, directory: directory)?.temporaryFiles.count, 0, "Java 8 cannot read one")
        XCTAssertEqual(launch(main(), classpath: long, version: nil, directory: directory)?.temporaryFiles.count, 0)
        XCTAssertEqual(launch(main { $0.shortenCommandLine = .none }, classpath: long, directory: directory)?.temporaryFiles.count, 0)
    }

    // MARK: - Instance main (JEP 445 / 512)

    func testTheNewLaunchProtocolNeedsPreviewOnJava21To24Only() {
        func flags(_ version: Int?, source: Bool = false) -> [String] {
            JavaLaunchCommand.newLaunchProtocolArguments(usesNewLaunchProtocol: true, jdkFeatureVersion: version, sourceLaunch: source)
        }
        XCTAssertEqual(flags(21), ["--enable-preview"])
        XCTAssertEqual(flags(24), ["--enable-preview"])
        XCTAssertEqual(flags(21, source: true), ["--enable-preview", "--source", "21"])
        XCTAssertEqual(flags(23, source: true), ["--enable-preview", "--source", "23"])
        XCTAssertEqual(flags(25), [], "final in Java 25")
        XCTAssertEqual(flags(26, source: true), [])
        XCTAssertEqual(flags(17), [], "too old: the caller reports it")
        XCTAssertEqual(flags(nil), [])
        XCTAssertEqual(
            JavaLaunchCommand.newLaunchProtocolArguments(usesNewLaunchProtocol: false, jdkFeatureVersion: 22, sourceLaunch: false), []
        )
    }

    func testAnInstanceMainRunsWithPreviewAheadOfTheUsersOptions() throws {
        let classpath = try XCTUnwrap(launch(main { $0.vmArguments = "-ea" }, version: 22, usesNewLaunchProtocol: true))
        XCTAssertEqual(classpath.arguments, ["--enable-preview", "-ea", "-cp", "/proj/app/classes:/lib/a.jar", "app.Main"])

        let single = JavaRunConfiguration(target: .singleFile(path: "/proj/Hello.java"), programArguments: "x")
        let source = JavaLaunchCommand.makeProcessLaunch(
            configuration: single, javaHome: home, runtimeClasspath: nil, projectRoot: project,
            jdkFeatureVersion: 21, usesNewLaunchProtocol: true, baseEnvironment: base
        )
        XCTAssertEqual(source?.arguments, ["--enable-preview", "--source", "21", "/proj/Hello.java", "x"])

        let current = JavaLaunchCommand.makeProcessLaunch(
            configuration: single, javaHome: home, runtimeClasspath: nil, projectRoot: project,
            jdkFeatureVersion: 25, usesNewLaunchProtocol: true, baseEnvironment: base
        )
        XCTAssertEqual(current?.arguments, ["/proj/Hello.java", "x"])
    }
}

