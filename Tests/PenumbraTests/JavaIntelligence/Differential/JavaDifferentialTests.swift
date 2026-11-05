import Foundation
import XCTest
@testable import JavaIntelligence

/// The symbol oracle and the differential baseline.
///
/// `testAttributeAgreesWithUmbraOnACrossFileCall` runs whenever a JDK is installed. The pinned
/// projects do not: set `JAVA_DIFFERENTIAL=1` to clone them (into `~/Library/Caches/umbra-differential`)
/// and score a bounded sample. `UPDATE_JAVA_DIFFERENTIAL=1` rewrites the baseline and
/// `docs/JAVA_DIFFERENTIAL.md`.
final class JavaDifferentialTests: XCTestCase {
    func testAttributeAgreesWithUmbraOnACrossFileCall() async throws {
        let environment = try ParityTestSupport.requireEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("differential-fixture-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bar = """
        public class Bar {
            public static String greet() { return "hi"; }
        }
        """
        let foo = """
        public class Foo {
            String test() { return Bar.greet(); }
            void print() { System.out.println("x"); }
        }
        """
        try bar.write(to: root.appendingPathComponent("Bar.java"), atomically: true, encoding: .utf8)
        let fooURL = root.appendingPathComponent("Foo.java")
        try foo.write(to: fooURL, atomically: true, encoding: .utf8)

        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk)
        do {
            try await client.configure(JavaAnalysisServerModule(moduleId: "fixture", sourcepath: [root]))
            let ns = foo as NSString
            let greet = ns.range(of: "greet()")
            let out = ns.range(of: ".out")
            let println = ns.range(of: "println")
            XCTAssertNotEqual(greet.location, NSNotFound)
            XCTAssertNotEqual(out.location, NSNotFound)
            XCTAssertNotEqual(println.location, NSNotFound)
            let greetPosition = greet.location + 4
            let outPosition = out.location + 3
            let printlnPosition = println.location + 6
            let symbols = try await client.attribute(
                moduleId: "fixture", file: fooURL, text: foo,
                positions: [greetPosition, outPosition, printlnPosition]
            )

            let greetSymbol = try XCTUnwrap(symbols.first { $0.position == greetPosition })
            XCTAssertEqual(greetSymbol.kind, "method")
            XCTAssertEqual(greetSymbol.name, "greet")
            XCTAssertEqual(greetSymbol.qualified, "Bar.greet")
            XCTAssertTrue(greetSymbol.declarationFile?.hasSuffix("Bar.java") == true, greetSymbol.declarationFile ?? "no file")
            XCTAssertEqual(greetSymbol.declarationStartLine, 2)

            let outSymbol = try XCTUnwrap(symbols.first { $0.position == outPosition })
            XCTAssertEqual(outSymbol.name, "out")
            XCTAssertEqual(outSymbol.qualified, "java.lang.System.out")
            XCTAssertNil(outSymbol.declarationFile)

            let printlnSymbol = try XCTUnwrap(symbols.first { $0.position == printlnPosition })
            XCTAssertEqual(printlnSymbol.kind, "method")
            XCTAssertEqual(printlnSymbol.name, "println")
            XCTAssertNil(printlnSymbol.declarationFile)

            let world = try await JavaDifferentialHarness.makeWorld(
                sourceRoot: root,
                jdkShard: try JavaDifferentialHarness.writeJDKShard(installation: environment.jdk),
                installation: environment.jdk
            )
            let site = JavaDifferentialHarness.IdentifierSite(
                name: "greet", startUTF16: greet.location, endUTF16: greet.location + 5
            )
            let verdict = await JavaDifferentialHarness.verdict(
                site: site, symbol: greetSymbol, text: foo, file: fooURL, world: world
            )
            XCTAssertTrue(verdict.definitionMatched, verdict.note)
            XCTAssertTrue(verdict.completionHit, verdict.note)
            XCTAssertTrue(verdict.hoverHit, verdict.note)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testPinnedProjectsHoldTheBaseline() async throws {
        guard ProcessInfo.processInfo.environment["JAVA_DIFFERENTIAL"] == "1" else {
            throw XCTSkip("Set JAVA_DIFFERENTIAL=1 to score gson and jackson-core, cloned into ~/Library/Caches/umbra-differential")
        }
        let report = try await JavaDifferentialHarness.run()
        print(report.summary)
        let resolved = report.projects.reduce(0) { $0 + $1.completionScored + $1.definitionScored }
        XCTAssertGreaterThan(resolved, 0, "the oracle resolved nothing\n\(report.summary)")
        if ProcessInfo.processInfo.environment["UPDATE_JAVA_DIFFERENTIAL"] == "1" {
            try report.save()
            return
        }
        guard let baseline = JavaDifferentialHarness.Report.load() else {
            XCTFail("no baseline.json: JAVA_DIFFERENTIAL=1 UPDATE_JAVA_DIFFERENTIAL=1 swift test --filter testPinnedProjectsHoldTheBaseline")
            return
        }
        if report.jdkFeature != baseline.jdkFeature {
            throw XCTSkip("baseline recorded on JDK \(baseline.jdkFeature); this JDK is \(report.jdkFeature)\n\(report.summary)")
        }
        let differences = report.differences(from: baseline)
        XCTAssertTrue(differences.isEmpty, differences.joined(separator: "\n"))
    }
}
