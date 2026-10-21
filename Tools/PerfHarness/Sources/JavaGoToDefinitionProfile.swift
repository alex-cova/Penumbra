import EditorIntelligence
import Foundation
import JavaIntelligence

/// Release-mode latency of ⌘-click (Go to Definition) through `JavaGoToDefinitionProvider`, the
/// call the editor makes for a click (`.manual`) and for ⌘-hover (`.idle`).
///
/// Indexes the JDK's `ct.sym` plus a generated project whose classes are real files on disk (the
/// target file is read and parsed per click), then times each kind of click in a large file,
/// cold (first request) and warm (the median of the next ones).
///
///   swift run -c release PerfHarness java-goto-definition synthetic [--lines N] [--samples N]
///
/// `PENUMBRA_GOTO_SITE=jdk_type` keeps only the sites whose name contains the text, so a sampler
/// sees one kind of click.
enum JavaGoToDefinitionProfile {
    private static let packageCount = 8
    private static let classesPerPackage = 25

    private struct Site {
        let name: String
        /// The click, as `before` + caret + `after` inside `void test(User u, List<String> names) { ... }`.
        let before: String
        let after: String
    }

    private static let sites: [Site] = [
        Site(name: "project_type", before: "", after: "User fresh = null;"),
        Site(name: "project_method", before: "u.", after: "getName();"),
        Site(name: "project_chain", before: "u.getAddress().", after: "getCity();"),
        Site(name: "project_constructor", before: "new ", after: "Address();"),
        Site(name: "project_big_class", before: "Type3x4 t = null; t.", after: "next();"),
        Site(name: "local_variable", before: "", after: "u.isActive();"),
        Site(name: "own_method", before: "", after: "helper0();"),
        Site(name: "jdk_type", before: "", after: "List<String> copy = names;"),
        Site(name: "jdk_method", before: "names.", after: "size();"),
        Site(name: "unresolved", before: "", after: "missing.call();")
    ]

    static func run(lines: Int, samples: Int) throws {
        let rows = try runBlocking { try await measure(lines: lines, samples: samples) }
        for row in rows { print(row) }
    }

    private static func measure(lines: Int, samples: Int) async throws -> [String] {
        guard let jdk = JDKLocator().select() else {
            throw ProfileFailure(message: "java-goto-definition needs an installed JDK")
        }
        note("=== java go to definition profile (JDK \(jdk.featureVersion), lines=\(lines)) ===")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-goto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = JavaIndex()
        let jdkShard = directory.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(try JDKCtSymRoot(installation: jdk).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)
        let projectShard = directory.appendingPathComponent("project.idx")
        try JavaIndexShardWriter().write(try writeProject(in: directory), stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard), shardPath: projectShard.path),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))
        ])
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: JavaIndexPaths(root: directory.appendingPathComponent("cache")))
        await provider.setJDKHome(jdk.home)

        var rows: [String] = []
        let only = ProcessInfo.processInfo.environment["PENUMBRA_GOTO_SITE"]
        for site in sites where only == nil || site.name.contains(only!) {
            let (text, offset) = currentFile(site: site, lines: lines)
            let url = directory.appendingPathComponent("src/com/perf/app/Current.java")
            for trigger in [RequestTrigger.manual, .idle] {
                var times: [Double] = []
                var resolved = "none"
                // Building the context scans the text for line and column; the editor has both already.
                let request = context(text: text, offset: offset, url: url, trigger: trigger)
                for iteration in 0 ..< (samples + 1) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = await provider.provide(context: request)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                    if iteration == 0 {
                        switch result {
                        case nil: resolved = "none"
                        case .single?: resolved = "single"
                        case .multiple(let all)?: resolved = "multiple(\(all.count))"
                        }
                    }
                }
                let cold = times[0]
                let warm = Array(times.dropFirst()).sorted()
                let median = warm[warm.count / 2]
                let label = trigger == .manual ? "click" : "hover"
                rows.append("stage java_goto_definition site=\(site.name) trigger=\(label) result=\(resolved) cold_s=\(format(cold)) warm_median_s=\(format(median)) warm_worst_s=\(format(warm.last ?? 0))")
            }
        }
        return rows
    }

    private static func context(text: String, offset: Int, url: URL, trigger: RequestTrigger) -> NavigationContext {
        let prefix = (text as NSString).substring(to: offset)
        let lineStarts = prefix.components(separatedBy: "\n")
        let position = TextPosition(line: lineStarts.count - 1, column: (lineStarts.last ?? "").utf16.count, utf16Offset: offset)
        let document = Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        return NavigationContext(document: document, cursor: Cursor(position: position), selection: document.selection, trigger: trigger, kind: .definition)
    }

    /// The file being edited: `lines` of unrelated methods around one `test` method holding the click.
    private static func currentFile(site: Site, lines: Int) -> (text: String, offset: Int) {
        var out = [
            "package com.perf.app;",
            "",
            "import com.perf.p0.*;",
            "import com.perf.p3.*;",
            "import java.util.*;",
            "",
            "public class Current {"
        ]
        var index = 0
        while out.count < lines {
            out.append("    int field\(index) = \(index);")
            out.append("    String helper\(index)() {")
            out.append("        int total = field\(index);")
            out.append("        for (int i = 0; i < total; i++) { total += i; }")
            out.append("        return String.valueOf(total);")
            out.append("    }")
            index += 1
        }
        let head = out.joined(separator: "\n") + "\n    void test(User u, List<String> names) {\n        " + site.before
        let text = head + site.after + "\n    }\n}\n"
        return (text, (head as NSString).length)
    }

    /// Two shared classes plus `packageCount * classesPerPackage` ~60-line classes, as real files.
    private static func writeProject(in directory: URL) throws -> [JavaClassStub] {
        var stubs: [JavaClassStub] = []
        func add(_ source: String, _ relativePath: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs += JavaSourceStubBuilder.build(source: source, url: url).classes
        }
        try add("""
        package com.perf.p0;
        public class User {
            public String getName() { return ""; }
            public Address getAddress() { return null; }
            public boolean isActive() { return true; }
        }
        """, "src/com/perf/p0/User.java")
        try add("""
        package com.perf.p0;
        public class Address {
            public String getCity() { return ""; }
            public int getZip() { return 0; }
        }
        """, "src/com/perf/p0/Address.java")
        for package in 0 ..< packageCount {
            for type in 0 ..< classesPerPackage {
                var body = ["package com.perf.p\(package);", "public class Type\(package)x\(type) {"]
                for member in 0 ..< 8 {
                    body.append("    private int value\(member) = \(member);")
                    body.append("    public String name\(member)(String prefix) {")
                    body.append("        StringBuilder out = new StringBuilder(prefix);")
                    body.append("        for (int i = 0; i < value\(member); i++) { out.append(i); }")
                    body.append("        return out.toString();")
                    body.append("    }")
                }
                body.append("    public Type\(package)x\(type) next() { return this; }")
                body.append("}")
                try add(body.joined(separator: "\n"), "src/com/perf/p\(package)/Type\(package)x\(type).java")
            }
        }
        return stubs
    }

    private static func format(_ value: Double) -> String { String(format: "%.6f", value) }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = GoToBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class GoToBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private struct ProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
