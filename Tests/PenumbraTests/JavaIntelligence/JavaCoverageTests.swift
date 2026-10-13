import JavaIntelligence
import XCTest

/// Locates `Tests/PenumbraTests/Fixtures/JavaCoverage` and `JavaProfiling` in the test bundle.
enum InstrumentationFixtures {
    static func url(_ folder: String, _ name: String) -> URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("no resourceURL") }
        for candidate in [
            resourceURL.appendingPathComponent(folder).appendingPathComponent(name),
            resourceURL.appendingPathComponent("Fixtures/\(folder)/\(name)")
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        fatalError("Could not locate \(folder)/\(name) in \(resourceURL)")
    }
}

final class JaCoCoXMLReportParserTests: XCTestCase {
    private func calcReport(sourceLookup: (String) -> URL? = { _ in nil }) throws -> JavaCoverageReport {
        try JaCoCoXMLReportParser.parse(contentsOf: InstrumentationFixtures.url("JavaCoverage", "calc-report.xml"), sourceLookup: sourceLookup)
    }

    func testParsesPackagesClassesAndTotals() throws {
        let report = try calcReport()
        XCTAssertEqual(report.name, "Fixture")
        XCTAssertEqual(report.packages.map(\.name), ["app"])
        let package = try XCTUnwrap(report.packages.first)
        XCTAssertEqual(package.classes.map(\.binaryName), ["app/Calc"])
        XCTAssertEqual(package.classes.first?.sourceFileName, "Calc.java")
        XCTAssertEqual(package.classes.first?.displayName, "Calc")
        XCTAssertEqual(report.totals.lines, JavaCoverageCounter(missed: 3, covered: 7))
        XCTAssertEqual(report.totals.branches, JavaCoverageCounter(missed: 2, covered: 4))
        XCTAssertEqual(report.totals.instructions, JavaCoverageCounter(missed: 7, covered: 20))
        XCTAssertEqual(report.totals.methods, JavaCoverageCounter(missed: 2, covered: 2))
        XCTAssertEqual(report.totals.classes, JavaCoverageCounter(missed: 0, covered: 1))
        XCTAssertEqual(report.totals.lines.percent, 70)
    }

    func testLineStatusesFollowJaCoCosRule() throws {
        let file = try XCTUnwrap(calcReport().sourceFiles.first)
        XCTAssertEqual(file.name, "Calc.java")
        XCTAssertEqual(file.relativePath, "app/Calc.java")
        XCTAssertEqual(file.status(atLine: 2), .missed)    // implicit constructor, never run
        XCTAssertEqual(file.status(atLine: 4), .partial)   // `if (n < 0)`: one branch not taken
        XCTAssertEqual(file.status(atLine: 5), .missed)    // `return -1`
        XCTAssertEqual(file.status(atLine: 7), .partial)   // `n == 0 || n > 100`
        XCTAssertEqual(file.status(atLine: 8), .covered)
        XCTAssertNil(file.status(atLine: 3), "a line with no code has no status")
        XCTAssertNil(file.status(atLine: 99))
    }

    func testBandsMergeAdjacentLinesOfOneStatus() throws {
        let file = try XCTUnwrap(calcReport().sourceFiles.first)
        // lines: 2 missed | 4 partial | 5 missed | 7 partial | 8 covered | 10 covered | 13 missed | 16,17,18 covered
        XCTAssertEqual(file.bands, [
            JavaCoverageBand(lines: 2...2, status: .missed),
            JavaCoverageBand(lines: 4...4, status: .partial),
            JavaCoverageBand(lines: 5...5, status: .missed),
            JavaCoverageBand(lines: 7...7, status: .partial),
            JavaCoverageBand(lines: 8...8, status: .covered),
            JavaCoverageBand(lines: 10...10, status: .covered),
            JavaCoverageBand(lines: 13...13, status: .missed),
            JavaCoverageBand(lines: 16...18, status: .covered)
        ])
    }

    func testNextAndPreviousUncoveredWrap() throws {
        let file = try XCTUnwrap(calcReport().sourceFiles.first)
        XCTAssertEqual(file.nextUncovered(after: 5), 7)
        XCTAssertEqual(file.nextUncovered(after: 13), 2, "wraps to the first")
        XCTAssertEqual(file.previousUncovered(before: 4), 2)
        XCTAssertEqual(file.previousUncovered(before: 2), 13, "wraps to the last")
    }

    func testSourceLookupResolvesFilesByPackagePath() throws {
        var asked: [String] = []
        let report = try calcReport { path in
            asked.append(path)
            return URL(fileURLWithPath: "/project/src/main/java/" + path)
        }
        XCTAssertEqual(asked, ["app/Calc.java"])
        let url = URL(fileURLWithPath: "/project/src/main/java/app/Calc.java")
        XCTAssertEqual(report.sourceFile(at: url)?.name, "Calc.java")
        XCTAssertNil(report.sourceFile(at: URL(fileURLWithPath: "/elsewhere/Calc.java")))
    }

    func testPartialBranchesMakeAPartialLine() {
        // 3 of 4 instructions ran but a branch did not: partial, as JaCoCo colours it yellow.
        let line = JavaCoverageLine(number: 9, missedInstructions: 0, coveredInstructions: 4, missedBranches: 1, coveredBranches: 1)
        XCTAssertEqual(line.status, .partial)
        XCTAssertEqual(JavaCoverageLine(number: 1, missedInstructions: 0, coveredInstructions: 3).status, .covered)
        XCTAssertEqual(JavaCoverageLine(number: 1, missedInstructions: 3, coveredInstructions: 0).status, .missed)
    }

    func testNestedClassesGroupsAndEmptySourceFiles() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <report name="multi"><group name="m"><package name="com/acme/shop">
          <class name="com/acme/shop/Order" sourcefilename="Order.java"><counter type="CLASS" missed="0" covered="1"/></class>
          <class name="com/acme/shop/Order$Line" sourcefilename="Order.java"><counter type="CLASS" missed="1" covered="0"/></class>
          <sourcefile name="Order.java"><line nr="3" mi="0" ci="2" mb="0" cb="0"/><counter type="LINE" missed="0" covered="1"/></sourcefile>
          <sourcefile name="Empty.java"/>
          <counter type="LINE" missed="0" covered="1"/>
        </package></group></report>
        """
        let report = try JaCoCoXMLReportParser.parse(Data(xml.utf8))
        let package = try XCTUnwrap(report.packages.first)
        XCTAssertEqual(package.name, "com.acme.shop")
        XCTAssertEqual(package.classes.map(\.displayName), ["Order", "Order.Line"])
        XCTAssertEqual(package.sourceFiles.map(\.name), ["Order.java", "Empty.java"])
        XCTAssertEqual(package.sourceFiles[1].lines, [])
        XCTAssertEqual(package.sourceFiles[1].bands, [])
        XCTAssertEqual(package.sourceFiles[0].packageName, "com.acme.shop")
        XCTAssertEqual(package.totals.lines.covered, 1)
    }

    func testTheDTDIsNeverFetched() throws {
        // A DOCTYPE whose system id cannot be reached: a parser that resolved it would stall or fail.
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <!DOCTYPE report PUBLIC "-//JACOCO//DTD Report 1.1//EN" "http://127.0.0.1:9/never/report.dtd">
        <report name="offline"><counter type="LINE" missed="1" covered="1"/></report>
        """
        let started = Date()
        let report = try JaCoCoXMLReportParser.parse(Data(xml.utf8))
        XCTAssertEqual(report.totals.lines, JavaCoverageCounter(missed: 1, covered: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRejectsNonReportsAndBrokenXML() {
        XCTAssertThrowsError(try JaCoCoXMLReportParser.parse(Data("<html/>".utf8))) {
            XCTAssertEqual($0 as? JaCoCoReportError, .notAReport)
        }
        XCTAssertThrowsError(try JaCoCoXMLReportParser.parse(Data("<report><package".utf8))) {
            guard case .malformed = $0 as? JaCoCoReportError else { return XCTFail("expected malformed, got \($0)") }
        }
    }

    func testPercentRoundsDownAndEmptyHasNone() {
        XCTAssertEqual(JavaCoverageCounter(missed: 1, covered: 999).percent, 99)
        XCTAssertNil(JavaCoverageCounter().percent)
        XCTAssertNil(JavaCoverageCounter().ratio)
    }
}

final class JavaCoverageCommandTests: XCTestCase {
    func testIncludesKeepOnlyTopLevelPackages() {
        let includes = JavaCoverageCommand.includes(packages: [
            "com.acme.shop", "com.acme.shop.model", "com.acme.util", "org.example", "com.acme.shopping"
        ])
        // `com.acme.shop.model` is covered by `com.acme.shop.*`; `com.acme.shopping` is a sibling, not a child.
        XCTAssertEqual(includes, "com.acme.shop.*:com.acme.shopping.*:com.acme.util.*:org.example.*")
    }

    func testDefaultPackageClassesAreNamedAndNothingMeansEverything() {
        XCTAssertEqual(JavaCoverageCommand.includes(packages: ["", "app"], defaultPackageClasses: ["Main", "Helper"]), "app.*:Helper:Main")
        XCTAssertEqual(JavaCoverageCommand.includes(packages: ["Main"]), "Main.*")
        XCTAssertNil(JavaCoverageCommand.includes(packages: [""]))
        XCTAssertNil(JavaCoverageCommand.includes(packages: []))
    }

    func testAgentArgument() throws {
        let argument = JavaCoverageCommand.agentArgument(
            agentJar: URL(fileURLWithPath: "/Applications/Umbra.app/Contents/Resources/jacocoagent.jar"),
            execFile: URL(fileURLWithPath: "/cache/run/root-test.exec"),
            includes: "app.*"
        )
        XCTAssertEqual(
            argument,
            "-javaagent:/Applications/Umbra.app/Contents/Resources/jacocoagent.jar=destfile=/cache/run/root-test.exec,append=true,includes=app.*,output=file"
        )
        let noIncludes = JavaCoverageCommand.agentArgument(
            agentJar: URL(fileURLWithPath: "/a.jar"), execFile: URL(fileURLWithPath: "/r/x.exec")
        )
        XCTAssertEqual(noIncludes, "-javaagent:/a.jar=destfile=/r/x.exec,append=true,output=file")
    }

    func testAgentArgumentRefusesPathsItsOptionSyntaxCannotCarry() {
        XCTAssertNil(JavaCoverageCommand.agentArgument(
            agentJar: URL(fileURLWithPath: "/a.jar"), execFile: URL(fileURLWithPath: "/runs/a,b/x.exec")
        ))
        XCTAssertNil(JavaCoverageCommand.agentArgument(
            agentJar: URL(fileURLWithPath: "/odd=dir/a.jar"), execFile: URL(fileURLWithPath: "/r/x.exec")
        ))
    }

    func testReportInvocationIsAnArgumentVector() {
        let call = JavaCoverageCommand.reportInvocation(
            java: URL(fileURLWithPath: "/jdk/bin/java"),
            cliJar: URL(fileURLWithPath: "/res/jacococli.jar"),
            executionFiles: [URL(fileURLWithPath: "/r/a.exec"), URL(fileURLWithPath: "/r/b.exec")],
            classDirectories: [URL(fileURLWithPath: "/p/app/build/classes/java/main"), URL(fileURLWithPath: "/p/lib/build/classes/java/main")],
            xmlOutput: URL(fileURLWithPath: "/r/report.xml"),
            name: "my project"
        )
        XCTAssertEqual(call.executable.path, "/jdk/bin/java")
        XCTAssertEqual(call.arguments, [
            "-jar", "/res/jacococli.jar", "report", "/r/a.exec", "/r/b.exec",
            "--classfiles", "/p/app/build/classes/java/main", "--classfiles", "/p/lib/build/classes/java/main",
            "--xml", "/r/report.xml", "--name", "my project"
        ])
    }

    func testToolchainLocateAndLanguageLevel() throws {
        let present: Set<String> = ["/bundle/jacocoagent.jar", "/bundle/jacococli.jar", "/dev/jacocoagent.jar"]
        let toolchain = try JavaCoverageToolchain.locate(
            in: [URL(fileURLWithPath: "/dev"), URL(fileURLWithPath: "/bundle")], fileExists: { present.contains($0) }
        )
        XCTAssertEqual(toolchain.agentJar.path, "/bundle/jacocoagent.jar", "a directory with only one jar is skipped")
        XCTAssertThrowsError(try JavaCoverageToolchain.locate(in: [URL(fileURLWithPath: "/dev")], fileExists: { present.contains($0) })) {
            XCTAssertEqual($0 as? JavaCoverageToolchain.LocateError, .notBundled(missing: ["jacococli.jar"]))
        }
        XCTAssertNil(JavaCoverageToolchain.unsupportedLanguageLevel(21))
        XCTAssertNil(JavaCoverageToolchain.unsupportedLanguageLevel(nil))
        XCTAssertEqual(JavaCoverageToolchain.supportedFeatureVersion, 26)
        XCTAssertNotNil(JavaCoverageToolchain.unsupportedLanguageLevel(27))
    }

    func testGradleScriptArgumentsAndMarkers() {
        let arguments = JavaCoverageGradleScript.arguments(
            scriptURL: URL(fileURLWithPath: "/r/coverage.init.gradle"),
            agentJar: URL(fileURLWithPath: "/res/jacocoagent.jar"),
            executionDirectory: URL(fileURLWithPath: "/r/exec"),
            includes: "app.*"
        )
        XCTAssertEqual(arguments, [
            "--init-script", "/r/coverage.init.gradle", "-PumbraCoverageAgent=/res/jacocoagent.jar",
            "-PumbraCoverageDir=/r/exec", "-PumbraCoverageIncludes=app.*", "--no-configuration-cache", "--no-build-cache"
        ])
        let output = """
        > Task :app:test
        ##umbra-coverage|exec|/r/exec/app-test.exec
        ##umbra-coverage|exec|/project/lib/build/jacoco/test.exec
        ##umbra-coverage|exec|/r/exec/app-test.exec
        BUILD SUCCESSFUL
        """
        XCTAssertEqual(JavaCoverageGradleScript.execFiles(inOutput: output).map(\.path), [
            "/r/exec/app-test.exec", "/project/lib/build/jacoco/test.exec"
        ])
        XCTAssertTrue(JavaCoverageGradleScript.source.contains("umbraCoverageAgent"))
    }
}

final class JavaCoverageScopeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDiscoversDeclaredPackagesNotDirectoryNames() throws {
        try write("src/main/java/com/acme/shop/Order.java", "package com.acme.shop;\npublic class Order {}\n")
        try write("src/main/java/com/acme/shop/model/Line.java", "/* package fake.header; */\n// package nope;\npackage com.acme.shop.model;\nclass Line {}\n")
        // The layout does not follow the package: the declaration wins.
        try write("src/main/java/odd/Thing.java", "package org.example.util;\nclass Thing {}\n")
        try write("src/main/java/Main.java", "public class Main { }\n")
        try write("src/main/java/Helper.java", "class Helper { }\n")
        let discovered = JavaCoveragePackages.discover(in: [root.appendingPathComponent("src/main/java")])
        XCTAssertEqual(discovered.packages, ["com.acme.shop", "com.acme.shop.model", "org.example.util"])
        XCTAssertEqual(discovered.defaultPackageClasses, ["Helper", "Main"])
        XCTAssertEqual(
            JavaCoverageCommand.includes(packages: discovered.packages, defaultPackageClasses: discovered.defaultPackageClasses),
            "com.acme.shop.*:org.example.util.*:Helper:Main"
        )
    }

    func testScopeFromGradleModelSkipsTestsAndResources() {
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: root,
            sourceSets: [
                .init(name: "main", sourceDirs: [root.appendingPathComponent("app/src/main/java")], outputDirs: [
                    root.appendingPathComponent("app/build/classes/java/main"),
                    root.appendingPathComponent("app/build/resources/main")
                ]),
                .init(name: "test", sourceDirs: [root.appendingPathComponent("app/src/test/java")], outputDirs: [
                    root.appendingPathComponent("app/build/classes/java/test")
                ])
            ]
        )
        let model = JavaGradleProjectModel(formatVersion: 7, gradleVersion: "9", subprojects: [app])
        let scope = JavaCoverageScope.make(model: model)
        XCTAssertEqual(scope.classDirectories.map(\.lastPathComponent), ["main"])
        XCTAssertEqual(scope.classDirectories.first?.path.hasSuffix("app/build/classes/java/main"), true)
        let withTests = JavaCoverageScope.make(model: model, includeTests: true)
        XCTAssertEqual(withTests.classDirectories.count, 2)
    }
}

final class JavaCoverageReportFilterTests: XCTestCase {
    func testFilteringKeepsAPackageAndItsSubpackagesAndSumsTheTotalsAgain() {
        func package(_ name: String, covered: Int, missed: Int) -> JavaCoveragePackage {
            var totals = JavaCoverageTotals()
            totals.lines = JavaCoverageCounter(missed: missed, covered: covered)
            return JavaCoveragePackage(name: name, totals: totals)
        }
        var totals = JavaCoverageTotals()
        totals.lines = JavaCoverageCounter(missed: 6, covered: 14)
        let report = JavaCoverageReport(name: "r", packages: [
            package("com.acme", covered: 4, missed: 1),
            package("com.acme.shop", covered: 6, missed: 2),
            package("com.acmeextra", covered: 4, missed: 3)
        ], totals: totals)
        let filtered = report.filtered(toPackagePrefixes: ["com.acme"])
        XCTAssertEqual(filtered.packages.map(\.name), ["com.acme", "com.acme.shop"], "a longer name that merely starts with the letters is not kept")
        XCTAssertEqual(filtered.totals.lines, JavaCoverageCounter(missed: 3, covered: 10))
        XCTAssertEqual(report.filtered(toPackagePrefixes: []), report)
        XCTAssertEqual(report.filtered(toPackagePrefixes: [" ", ""]), report)
        XCTAssertTrue(report.filtered(toPackagePrefixes: ["org"]).packages.isEmpty)
    }
}
