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
                site: site, symbol: greetSymbol, text: foo, file: fooURL, world: world,
                roles: JavaDifferentialHarness.roleMap(in: foo), sourceRoot: root
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

    /// The J1 flip on a tiny stub index: `aa` is declared after twelve `aaN` fields, so raw
    /// provider order buries it past the top-8, while the ranked popup's exact-tier match puts
    /// it first. Fails before ranking, passes after — the case the old scorer could not see.
    func testRankedPopupBeatsProviderOrderOnATinyIndex() async throws {
        let environment = try ParityTestSupport.requireEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("differential-rank-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var fields = (1...12).map { "        public int aa\($0) = \($0);" }.joined(separator: "\n")
        fields += "\n        public int aa = 100;"
        let flip = """
        public class Flip {
        \(fields)
            int use(Flip f) { return f.aa; }
        }
        """
        let flipURL = root.appendingPathComponent("Flip.java")
        try flip.write(to: flipURL, atomically: true, encoding: .utf8)

        let world = try await JavaDifferentialHarness.makeWorld(
            sourceRoot: root,
            jdkShard: try JavaDifferentialHarness.writeJDKShard(installation: environment.jdk),
            installation: environment.jdk
        )
        let ns = flip as NSString
        let use = ns.range(of: "f.aa")
        XCTAssertNotEqual(use.location, NSNotFound)
        let site = JavaDifferentialHarness.IdentifierSite(
            name: "aa", startUTF16: use.location + 2, endUTF16: use.location + 4
        )
        let symbol = JavaAnalysisSymbol(
            position: site.lastUTF16, kind: "field", name: "aa", qualified: "Flip.aa",
            declarationFile: nil, declarationStartLine: nil, declarationEndLine: nil
        )
        let verdict = await JavaDifferentialHarness.verdict(
            site: site, symbol: symbol, text: flip, file: flipURL, world: world,
            roles: JavaDifferentialHarness.roleMap(in: flip), sourceRoot: root
        )
        XCTAssertFalse(verdict.legacyCompletionHit, "provider-order top-8 should miss buried `aa`: \(verdict.note)")
        XCTAssertEqual(verdict.completionRank, 1, verdict.note)
        XCTAssertTrue(verdict.completionHit, verdict.note)
        XCTAssertEqual(verdict.siteRole, .member, verdict.note)
        XCTAssertTrue(verdict.siteDotted, verdict.note)
    }

    /// The tail is deleted: with the caret mid-identifier, the completion buffer holds the
    /// typed prefix plus whatever follows the identifier, never the identifier's own tail.
    func testCompletionBufferDeletesTheIdentifierTail() {
        let text = "foo fromJson bar"
        let ns = text as NSString
        let range = ns.range(of: "fromJson")
        let site = JavaDifferentialHarness.IdentifierSite(
            name: "fromJson", startUTF16: range.location, endUTF16: NSMaxRange(range)
        )
        XCTAssertEqual(
            JavaDifferentialHarness.completionBuffer(text: text, site: site, typedLength: 2),
            "foo fr bar"
        )
    }

    /// Non-ratcheting diagnostic run: the same scorer with `JAVA_DIFFERENTIAL_FILES` and
    /// `JAVA_DIFFERENTIAL_POSITIONS` overrides, printing the three headline rates and the
    /// rank-bucket table per role. Never fails on sample shape.
    func testSliceReportPrintsRankBucketsPerRole() async throws {
        guard ProcessInfo.processInfo.environment["JAVA_DIFFERENTIAL_REPORT"] == "1" else {
            throw XCTSkip("Set JAVA_DIFFERENTIAL_REPORT=1 to print rank buckets per role (uses JAVA_DIFFERENTIAL_FILES / JAVA_DIFFERENTIAL_POSITIONS overrides)")
        }
        let report = try await JavaDifferentialHarness.run()
        print(report.summary)
        let resolved = report.projects.reduce(0) { $0 + $1.completionScored + $1.definitionScored }
        XCTAssertGreaterThan(resolved, 0, "the oracle resolved nothing\n\(report.summary)")
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

    /// H1: the sampler drops words inside comments and strings, including the shapes the
    /// old line-based check leaked: trailing `//` comments and inner `/* */` lines.
    func testIdentifierSitesExcludesCommentsAndStrings() {
        let source = """
        package com.example;
        /** Javadoc words like HelperFactory are not code. */
        public class CommentSampler {
            // trailing words like TrailingWidget should not sample
            /* block words like BlockGadget
               inner words like InnerSprocket span lines */
            String fieldName = "string words like StringLiteral do not count";
            void helperMethod() {
                int localName = fieldName.length(); // call words like CallWidget leaked before
            }
        }
        """
        let sampled = JavaDifferentialHarness.identifierSites(in: source, limit: 100)
        let names = Set(sampled.sites.map(\.name))
        for leaked in ["HelperFactory", "TrailingWidget", "BlockGadget", "InnerSprocket", "StringLiteral", "CallWidget"] {
            XCTAssertFalse(names.contains(leaked), "\(leaked) sampled from a comment or string")
        }
        for kept in ["CommentSampler", "fieldName", "helperMethod", "localName", "length"] {
            XCTAssertTrue(names.contains(kept), "\(kept) missing from sampled sites")
        }
        XCTAssertGreaterThan(sampled.excluded, 0, "nothing sampled out")
        XCTAssertGreaterThan(sampled.leaks, 0, "the old check leaked nothing here")
    }
}
