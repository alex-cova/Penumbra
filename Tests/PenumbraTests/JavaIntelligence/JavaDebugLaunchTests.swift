import XCTest
@testable import JavaIntelligence

final class JavaDebugLaunchTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-debug-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testClasspathMainSupportsDebugLaunch() {
        let configuration = JavaRunConfiguration(
            target: .classpathMain(className: "demo.Main", sourceFile: "/proj/Main.java"),
            launchMode: .debug,
            jdwpPort: 5005,
            suspendOnStart: true
        )
        XCTAssertTrue(configuration.supportsDebugLaunch)
        XCTAssertEqual(configuration.launchMode, .debug)
        XCTAssertEqual(configuration.jdwpPort, 5005)
        XCTAssertTrue(configuration.suspendOnStart)
    }

    func testGradleRunSupportsDebugLaunch() {
        let configuration = JavaRunConfiguration(target: .gradleRun(projectPath: ":app"), launchMode: .debug)
        XCTAssertTrue(configuration.supportsDebugLaunch)
    }

    func testGradleDebugRunArgumentsIncludeDebugJvmFlag() {
        let configuration = JavaRunConfiguration(
            target: .gradleRun(projectPath: ":app"),
            programArguments: "one two"
        )
        let args = JavaLaunchCommand.gradleRunArguments(configuration: configuration, debug: true)
        XCTAssertTrue(args.contains("--debug-jvm"))
        XCTAssertTrue(args.contains { $0.hasPrefix("--args=") })
    }

    func testSingleFileDoesNotSupportDebugLaunch() {
        let configuration = JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"), launchMode: .debug)
        XCTAssertFalse(configuration.supportsDebugLaunch)
    }

    func testJDWPAgentIncludesPortAndSuspendFlag() {
        XCTAssertEqual(
            JavaLaunchCommand.jdwpAgent(port: 5005, suspend: true),
            "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"
        )
        XCTAssertEqual(
            JavaLaunchCommand.jdwpAgent(port: 8000, suspend: false),
            "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:8000"
        )
    }

    func testMakeManagedLaunchAppendsJDWPAgentAndSplitsArguments() throws {
        let home = scratch.appendingPathComponent("jdk")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let java = bin.appendingPathComponent("java")
        try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)

        let classpath = [scratch.appendingPathComponent("classes")]
        let configuration = JavaRunConfiguration(
            target: .classpathMain(className: "demo.Main", sourceFile: "/proj/Main.java"),
            programArguments: "one \"two words\"",
            vmArguments: "-Xmx512m",
            environment: ["MODE": "dev"],
            launchMode: .debug,
            suspendOnStart: false
        )
        let launch = try XCTUnwrap(JavaLaunchCommand.makeManagedLaunch(
            configuration: configuration, javaHome: home, runtimeClasspath: classpath, jdwpPort: 9000
        ))
        XCTAssertEqual(launch.mainClass, "demo.Main")
        XCTAssertEqual(launch.classpath, classpath)
        XCTAssertEqual(launch.programArguments, ["one", "\"two", "words\""])
        XCTAssertEqual(launch.environment, ["MODE": "dev"])
        XCTAssertEqual(launch.jdwpPort, 9000)
        XCTAssertFalse(launch.suspendOnStart)
        XCTAssertTrue(launch.vmArguments.contains("-Xmx512m"))
        XCTAssertTrue(launch.vmArguments.contains { $0.contains("jdwp") && $0.contains("9000") && $0.contains("suspend=n") })
    }

    func testMakeManagedLaunchRequiresDebugModeAndClasspath() throws {
        let home = scratch.appendingPathComponent("jdk")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let java = bin.appendingPathComponent("java")
        try Data().write(to: java)

        let runConfiguration = JavaRunConfiguration(
            target: .classpathMain(className: "demo.Main", sourceFile: "/proj/Main.java"),
            launchMode: .run
        )
        XCTAssertNil(JavaLaunchCommand.makeManagedLaunch(
            configuration: runConfiguration, javaHome: home, runtimeClasspath: [scratch], jdwpPort: 5005
        ))
        let debugConfiguration = JavaRunConfiguration(
            target: .classpathMain(className: "demo.Main", sourceFile: "/proj/Main.java"),
            launchMode: .debug
        )
        XCTAssertNil(JavaLaunchCommand.makeManagedLaunch(
            configuration: debugConfiguration, javaHome: home, runtimeClasspath: [], jdwpPort: 5005
        ))
    }

    func testDebugFieldsRoundTripThroughCodable() throws {
        let configuration = JavaRunConfiguration(
            target: .classpathMain(className: "demo.Main", sourceFile: "/proj/Main.java"),
            launchMode: .debug,
            jdwpPort: 5005,
            suspendOnStart: false
        )
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(JavaRunConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
    }
}
