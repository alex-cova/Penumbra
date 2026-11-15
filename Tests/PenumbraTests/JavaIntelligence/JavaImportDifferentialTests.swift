import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// Umbra's `unresolved-type` / `unresolved-import` against `javac -XDrawDiagnostics`, per line,
/// on every installed JDK (each at its own release, plus `--release 8/17/21` when the JDK can
/// target them). Both sides see the same artifacts: the JDK's own platform classes (Umbra through
/// `JDKIndexRoot`, the shard Umbra itself indexes), and one dependency jar compiled here, which
/// `javac` reads from `-cp` and Umbra indexes through `JarRoot` like a Gradle dependency.
///
/// Every disagreement is classified and printed (`DIFF` lines, then a `DIFFSUMMARY` per JDK):
/// - `falsePositive`: Umbra reports, `javac` accepts. Always fails the test.
/// - `falseNegative`: `javac` reports a resolution error Umbra does not. Fails unless the case
///   declares it (`//! expect-gap: <reason>`).
/// - `featureDifference`: by design (a type one import away belongs to auto-import, not this rule).
/// - `unsupported`: a case marked `//! unsupported: <reason>`; its lines are compared and printed
///   but never fail.
/// - `configurationMismatch`: `--release N` below the JDK: `javac` reads release N's API from
///   `ct.sym`, Umbra indexes the JDK's own release. Printed, never fails.
///
/// Skipped without a JDK. Runs in a few seconds per JDK (one `javac` per case).
final class JavaImportDifferentialTests: XCTestCase {
    // MARK: - Corpus

    private static let library: [String: String] = [
        "lib/Hidden.java": "package lib; class Hidden { }",
        "lib/Visible.java": "package lib; public class Visible { private static class Secret { } public static class Open { } }",
        "lib/Super.java": "package lib; public class Super { public static final int CONST = 1; public static class Inherited { } public static void util() { } }",
        "lib/Sub.java": "package lib; public class Sub extends Super { }",
        "lib/Gadget.java": "package lib; public class Gadget { }",
        "com/acme/List.java": "package com.acme; public class List { }",
    ]

    private struct Case {
        let name: String
        let source: String
    }

    private static let cases: [Case] = [
        Case(name: "Collision", source: """
        package app;
        import com.fake.List;
        class Collision { }
        """),
        Case(name: "SameNameTwoPackages", source: """
        package app;
        import com.acme.List;
        class SameNameTwoPackages { java.util.List<String> a; List b; }
        """),
        Case(name: "StaticImports", source: """
        package app;
        import static java.util.Collections.emptyList;
        import static java.util.Collections.EMPTY_LIST;
        import static java.util.Collections.*;
        import static java.util.Map.Entry;
        import static lib.Sub.CONST;
        import static lib.Sub.util;
        class StaticImports { }
        """),
        Case(name: "StaticMissing", source: """
        package app;
        import static java.util.Collections.noSuchMember;
        import static com.fake.Util.*;
        import static com.fake.Util.run;
        class StaticMissing { }
        """),
        Case(name: "Nested", source: """
        package app;
        import java.util.Map.Entry;
        import java.util.Map.Nope;
        import lib.Sub.Inherited;
        class Nested { Entry<String, String> e; Inherited i; }
        """),
        Case(name: "OnDemand", source: """
        package app;
        import java.util.*;
        import java.util.Map.*;
        import com.nowhere.*;
        class OnDemand { List<String> l; }
        """),
        Case(name: "Access", source: """
        package app;
        import lib.Hidden;
        import lib.Visible.Secret;
        import lib.Visible.Open;
        class Access { }
        """),
        Case(name: "Types", source: """
        package app;
        import java.util.concurrent.CompletableFuture;
        import java.time.LocalDate;
        import java.sql.Connection;
        class Types { String s; Object o; CompletableFuture<String> f; LocalDate d; Connection c; Missing m; }
        """),
        Case(name: "ImportableButNotImported", source: """
        package app;
        class ImportableButNotImported { Gadget g; }
        """),
        Case(name: "RemovedFromJDK", source: """
        package app;
        import javax.xml.bind.JAXBContext;
        class RemovedFromJDK { }
        """),
    ]

    // MARK: - Run

    private enum Kind: String { case match, falsePositive, falseNegative, featureDifference, unsupported, configurationMismatch }

    func testUmbraAgreesWithJavacOnResolution() async throws {
        let jdks = JDKLocator().discoverAll().filter { $0.javac != nil }
        try XCTSkipIf(jdks.isEmpty, "needs an installed JDK")
        // One per feature version, newest vendor build wins.
        var byVersion: [Int: JDKInstallation] = [:]
        for jdk in jdks where byVersion[jdk.featureVersion] == nil { byVersion[jdk.featureVersion] = jdk }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        print("DIFFJDKS \(byVersion.keys.sorted())")

        var failures: [String] = []
        for version in byVersion.keys.sorted() {
            let jdk = byVersion[version]!
            let work = scratch.appendingPathComponent("jdk\(version)", isDirectory: true)
            let jar = try buildLibraryJar(jdk: jdk, in: work)
            let index = try await makeIndex(jdk: jdk, jar: jar, in: work)
            let releases = [nil] + [8, 17, 21].filter { $0 < version }.map(Optional.some)
            for release in releases {
                var counts: [Kind: Int] = [:]
                for testCase in Self.cases {
                    let results = try await compare(testCase, jdk: jdk, release: release, jar: jar, index: index, work: work)
                    for (line, kind, detail) in results {
                        counts[kind, default: 0] += 1
                        if kind != .match {
                            print("DIFF jdk=\(version) release=\(release.map(String.init) ?? "own") \(testCase.name):\(line) \(kind.rawValue) \(detail)")
                        }
                        if kind == .falsePositive || kind == .falseNegative {
                            failures.append("jdk \(version) release \(release.map(String.init) ?? "own") \(testCase.name):\(line) \(kind.rawValue) \(detail)")
                        }
                    }
                }
                print("DIFFSUMMARY jdk=\(version) release=\(release.map(String.init) ?? "own") " + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
            }
        }
        XCTAssertEqual(failures, [], "undeclared disagreements with javac")
    }

    // MARK: - One case

    private static let resolutionKeys = [
        "compiler.err.cant.resolve", "compiler.err.doesnt.exist", "compiler.err.not.def.public.cant.access",
        "compiler.err.report.access", "compiler.err.package.not.visible", "compiler.err.not.def.access.package.cant.access",
    ]

    private func compare(
        _ testCase: Case, jdk: JDKInstallation, release: Int?, jar: URL, index: JavaIndex, work: URL
    ) async throws -> [(Int, Kind, String)] {
        let dir = work.appendingPathComponent("case-\(testCase.name)-\(release ?? 0)", isDirectory: true)
        let file = dir.appendingPathComponent("app/\(testCase.name).java")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try testCase.source.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["-XDrawDiagnostics", "-proc:none", "-implicit:none", "-d", dir.appendingPathComponent("out").path, "-cp", jar.path]
        if let release { arguments += ["--release", String(release)] }
        let output = try run(jdk.javac!, arguments + [file.path])
        var javac: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            // `app/Case.java:3:8: compiler.err.cant.resolve.location: …`
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 4, let number = Int(parts[1]) else { continue }
            let key = parts[3].trimmingCharacters(in: .whitespaces)
            guard Self.resolutionKeys.contains(where: { key.hasPrefix($0) }) else { continue }
            javac[number] = javac[number].map { "\($0), \(key)" } ?? key
        }

        var options = JavaBatchInspector.Options(profile: .standard())
        options.onlyRules = [.unresolvedType, .unresolvedImport]
        let source = testCase.source
        let found = await JavaBatchInspector(index: index).inspect(url: file, options: options) { _ in source }
        var umbra: [Int: String] = [:]
        for finding in found {
            let line = finding.range.start.line + 1
            umbra[line] = umbra[line].map { "\($0), \(finding.message)" } ?? finding.message
        }

        let unsupported = testCase.source.contains("//! unsupported:")
        let declaredGaps = testCase.source.contains("//! expect-gap:")
        var results: [(Int, Kind, String)] = []
        for line in Set(javac.keys).union(umbra.keys).sorted() {
            let detail = "javac=[\(javac[line] ?? "")] umbra=[\(umbra[line] ?? "")]"
            let kind: Kind
            switch (javac[line] != nil, umbra[line] != nil) {
            case (true, true): kind = .match
            case (false, true):
                kind = release != nil ? .configurationMismatch : (unsupported ? .unsupported : .falsePositive)
            case (true, false):
                if release != nil { kind = .configurationMismatch }
                else if unsupported || declaredGaps { kind = .unsupported }
                else if await isImportableName(onLine: line, of: testCase.source, index: index) { kind = .featureDifference }
                else { kind = .falseNegative }
            case (false, false): continue
            }
            results.append((line, kind, detail))
        }
        return results
    }

    /// `javac` reports a simple type name the file never imports; Umbra leaves it to auto-import
    /// when some class of that name exists (`JavaUnresolvedTypeInspection`).
    private func isImportableName(onLine line: Int, of source: String, index: JavaIndex) async -> Bool {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard line - 1 < lines.count, !lines[line - 1].hasPrefix("import") else { return false }
        let words = lines[line - 1].split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.first?.isUppercase == true }
        for word in words where !(await index.classes(simpleName: word, limit: 1)).isEmpty {
            if source.contains("import") && source.contains(".\(word);") { continue }
            return true
        }
        return false
    }

    // MARK: - Fixtures

    private func buildLibraryJar(jdk: JDKInstallation, in work: URL) throws -> URL {
        let sources = work.appendingPathComponent("lib-src", isDirectory: true)
        let classes = work.appendingPathComponent("lib-classes", isDirectory: true)
        var files: [String] = []
        for (path, text) in Self.library {
            let url = sources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            files.append(url.path)
        }
        _ = try run(jdk.javac!, ["-proc:none", "--release", "8", "-d", classes.path] + files)
        let jar = work.appendingPathComponent("lib.jar")
        let jarTool = jdk.home.appendingPathComponent("bin/jar")
        _ = try run(jarTool, ["--create", "--file", jar.path, "-C", classes.path, "."])
        return jar
    }

    private func makeIndex(jdk: JDKInstallation, jar: URL, in work: URL) async throws -> JavaIndex {
        let (root, _) = JDKIndexRoot.make(for: jdk)
        let jdkShard = work.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(try root.readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)
        let jarShard = work.appendingPathComponent("lib.idx")
        try JavaIndexShardWriter().write(try JarRoot(jarURL: jar).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jarShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)),
            .init(precedence: 2, reader: try JavaIndexShardReader(url: jarShard)),
        ])
        return index
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
