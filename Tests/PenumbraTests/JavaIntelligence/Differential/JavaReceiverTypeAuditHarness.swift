import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// Receiver-type differential audit: at every member access `expr.name(...)` of real Java files, is the
/// type the engine gives `expr` the type javac gives it?
///
/// The oracle is javac itself. A file is compiled with a sample of its member accesses replaced by a
/// member that does not exist (`expr.zzProbe()`); for each, javac's `cannot find symbol` names the
/// receiver (`location: variable l of type ArrayList<String>`, or `location: interface Stream<CAP#1>`).
/// The engine is asked for the receiver at the same site of the *original* file, with the caret after the
/// dot, exactly as when typing. Nothing here changes the engine: it is a measurement.
///
///     JAVA_AUDIT=1 swift test --filter JavaReceiverTypeAuditTests
///
/// Knobs: `JAVA_AUDIT_SET=development|held-out|all` (default all), `JAVA_AUDIT_ONLY=jOOL,gson`, `JAVA_AUDIT_FILES` (30),
/// `JAVA_AUDIT_SITES` (80 per file), `JAVA_AUDIT_OUT=/path` (full report), `JAVA_AUDIT_EXAMPLES` (12 per bucket),
/// `JAVA_AUDIT_MEMBERS=/path` (every compared site that is not `exact`, as JSON lines with the engine's full member list,
/// for the independent member-set classification; it does not change any bucket).
enum JavaReceiverTypeAudit {
    struct Probe {
        let nodeType: String
        let line: Int
        let objectStart: Int
        let objectEnd: Int
        let dotByte: Int
        let replaceStart: Int
        let replaceEnd: Int
        let receiverText: String
        var tags: [String]
    }

    struct Record {
        let project: String
        let file: String
        let line: Int
        let receiver: String
        let javac: String
        let engine: String
        let bucket: String
        let tags: [String]
        let candidates: [String]
        // Filled only with `JAVA_AUDIT_MEMBERS` (the semantic classification, docs/JAVA_RECEIVER_FIDELITY_FINAL_AUDIT.md).
        // They never feed `bucket`.
        var path: String? = nil
        var engineRaw: String? = nil
        var members: [String]? = nil
        /// `label@origin`. An empty origin means the completion item treats the member as the receiver's own.
        var origins: [String]? = nil
        var receiverUTF16: [Int]? = nil
    }

    /// One line of `JAVA_AUDIT_MEMBERS`: a compared site that is not `exact`, with what an independent
    /// member-set oracle (`Tools/JavaReceiverOracle/ReceiverMemberOracle.java`) needs to judge it.
    struct MemberDump: Codable {
        let project: String
        let path: String
        let line: Int
        let receiver: String
        let receiverUTF16: [Int]
        let javac: String
        let engine: String
        let engineRaw: String
        let bucket: String
        let members: [String]
        /// `label@origin` for the same items as `members`. Empty origin means declared on the receiver.
        let origins: [String]
    }

    struct ProjectDump: Codable {
        let project: String
        let classpath: [String]
        let sourcepath: [String]
    }

    // MARK: - Sampling

    /// `markedOnly`: probe only the accesses written `receiver/*P*/.member`, for hand-written probe files.
    static func probes(in text: String, tree: JavaSyntaxTree, limit: Int, markedOnly: Bool = false) -> [Probe] {
        let bytes = tree.sourceBytes
        var all: [Probe] = []
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            stack += node.namedChildren
            guard node.type == "method_invocation" || node.type == "field_access",
                  let object = node.child(byFieldName: "object"),
                  let name = node.child(byFieldName: node.type == "field_access" ? "field" : "name"),
                  name.startByte > object.endByte else { continue }
            var inside = node.parent
            var skip = false
            while let ancestor = inside {
                if ["import_declaration", "package_declaration", "marker_annotation", "annotation", "annotation_argument_list"].contains(ancestor.type) { skip = true; break }
                inside = ancestor.parent
            }
            guard !skip, let dot = bytes[object.endByte..<name.startByte].firstIndex(of: 0x2E) else { continue }
            if markedOnly, !String(decoding: bytes[object.endByte..<dot], as: UTF8.self).contains("/*P*/") { continue }
            let end = node.type == "field_access" ? name.endByte : node.endByte
            let line = bytes[..<name.startByte].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
            var receiver = String(decoding: bytes[object.byteRange], as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            if receiver.count > 110 { receiver = String(receiver.prefix(107)) + "..." }
            all.append(Probe(
                nodeType: node.type, line: line, objectStart: object.startByte, objectEnd: object.endByte, dotByte: dot,
                replaceStart: name.startByte, replaceEnd: end, receiverText: receiver, tags: tags(of: object, in: tree)
            ))
        }
        // A deterministic shuffle, then greedily keep probes whose receiver-to-end ranges are disjoint,
        // so every kept probe's receiver text reaches javac intact.
        all.sort { ($0.dotByte &* 2654435761) % 1_000_003 < ($1.dotByte &* 2654435761) % 1_000_003 }
        var kept: [Probe] = []
        for probe in all where kept.count < limit {
            let range = probe.objectStart..<probe.replaceEnd
            if kept.contains(where: { $0.objectStart < range.upperBound && range.lowerBound < $0.replaceEnd }) { continue }
            kept.append(probe)
        }
        return kept.sorted { $0.dotByte < $1.dotByte }
    }

    /// Structural features of the receiver expression, for the per-feature tables.
    static func tags(of object: SyntaxNode, in tree: JavaSyntaxTree) -> [String] {
        var tags: [String] = []
        switch object.type {
        case "identifier":
            let locals = tree.visibleLocals(atByteOffset: object.startByte)
            if locals.first(where: { $0.name == object.text })?.lambdaOrigin != nil { tags.append("lambda-param") }
            else if locals.contains(where: { $0.name == object.text }) { tags.append("local-or-param") }
            else { tags.append("name") }
        case "method_invocation": tags.append("call")
        case "field_access": tags.append("field-path")
        case "parenthesized_expression": tags.append("parenthesized")
        case "object_creation_expression": tags.append("new")
        case "array_access": tags.append("array-access")
        case "cast_expression": tags.append("cast")
        case "this": tags.append("this")
        default: tags.append(object.type)
        }
        var stack = [object]
        var chainLength = 0
        while let node = stack.popLast() {
            switch node.type {
            case "lambda_expression":
                if !tags.contains("has-lambda") { tags.append("has-lambda") }
                if let body = node.child(byFieldName: "body"), body.type == "block", returnCount(in: body) >= 2, !tags.contains("multi-return-lambda") {
                    tags.append("multi-return-lambda")
                }
            case "method_reference": if !tags.contains("has-method-ref") { tags.append("has-method-ref") }
            case "ternary_expression": if !tags.contains("has-conditional") { tags.append("has-conditional") }
            case "method_invocation":
                chainLength += 1
                if node.child(byFieldName: "type_arguments") != nil, !tags.contains("explicit-type-args") { tags.append("explicit-type-args") }
            case "object_creation_expression": if node.text.contains("<>"), !tags.contains("diamond") { tags.append("diamond") }
            default: break
            }
            stack += node.namedChildren
        }
        if chainLength >= 3 { tags.append("long-chain") }
        return tags
    }

    private static func returnCount(in body: SyntaxNode) -> Int {
        var count = 0
        var stack = [body]
        while let node = stack.popLast() {
            if node.type == "lambda_expression" || node.type == "class_body" { continue }
            if node.type == "return_statement" { count += 1 }
            stack += node.namedChildren
        }
        return count
    }

    // MARK: - javac

    /// `text` with each probe's member (and arguments) replaced by `zzProbe` / `zzProbe()`, and the
    /// UTF-16 offset in the result of every probe's receiver start (javac reports `cannot find symbol`
    /// from the start of the selected expression, which is the receiver's first character).
    static func probedText(_ text: String, bytes: [UInt8], probes: [Probe]) -> (text: String, receiverStarts: [Int]) {
        var output: [UInt8] = []
        var cursor = 0
        var startBytes: [Int] = []
        for probe in probes {
            output += bytes[cursor..<probe.replaceStart]
            startBytes.append(output.count - (probe.replaceStart - probe.objectStart))
            output += Array((probe.nodeType == "field_access" ? "zzProbe" : "zzProbe()").utf8)
            cursor = probe.replaceEnd
        }
        output += bytes[cursor...]
        var starts: [Int] = []
        var decoded = 0
        var units = 0
        for start in startBytes {
            units += String(decoding: output[decoded..<start], as: UTF8.self).utf16.count
            decoded = start
            starts.append(units)
        }
        return (String(decoding: output, as: UTF8.self), starts)
    }

    /// The first line after `location:` in javac's `cannot find symbol`, without `variable x of type`.
    static func javacType(from message: String) -> String? {
        guard message.contains("zzProbe"), let range = message.range(of: "location:") else { return nil }
        var line = message[range.upperBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespaces)
        if let marker = line.range(of: " of type ") { line = String(line[marker.upperBound...]) }
        for prefix in ["class ", "interface ", "enum ", "@interface ", "record "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        return line.replacingOccurrences(of: ", ", with: ",").trimmingCharacters(in: .whitespaces)
    }

    /// javac's `capture#1 of ? extends U` read as the bound `U` (and `capture#1 of ? super U` as `?super U`, `capture#1 of ?` as
    /// `?`): what the engine's local approximation of capture conversion produces. `nil` when nothing was captured.
    static func uncaptured(_ javac: String) -> String? {
        guard javac.contains("capture#") || javac.contains("CAP#") else { return nil }
        var result = javac
        let patterns: [(String, String)] = [
            ("capture#\\d+ of \\? extends ([\\w.$\\[\\]]+(?:<[^<>]*>)?)", "$1"),
            ("capture#\\d+ of \\? super ([\\w.$\\[\\]]+(?:<[^<>]*>)?)", "?super $1"),
            ("capture#\\d+ of \\?", "?")
        ]
        for (pattern, template) in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    // MARK: - Comparison

    /// `java.util.Map.Entry<java.lang.String,java.lang.Integer>` and javac's `Entry<String,Integer>` both
    /// become `Entry<String,Integer>`.
    static func simplified(_ type: String) -> String {
        let expression = try! NSRegularExpression(pattern: "(?:[A-Za-z_$][\\w$]*\\.)+(?=[A-Za-z_$?])")
        let range = NSRange(type.startIndex..., in: type)
        return expression.stringByReplacingMatches(in: type, range: range, withTemplate: "")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "?", with: "?")
    }

    static func describe(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, let arguments, _):
            return arguments.isEmpty ? name : "\(name)<\(arguments.map(describe).joined(separator: ","))>"
        case .array(let element): return "\(describe(element))[]"
        case .primitive(let primitive): return primitive.rawValue
        case .typeVariable(let name): return name
        case .unresolved(let name, _): return "?\(name)"
        case .void: return "void"
        case .wildcard(let bound): return describe(bound)
        }
    }

    private static func describe(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type): return describe(type)
        case .wildcard(let bound): return describe(bound)
        }
    }

    private static func describe(_ bound: JavaWildcardBound?) -> String {
        switch bound {
        case .none: return "?"
        // With spaces: glued to a qualified name, `?super` + `java.lang.Integer` would read as one package path.
        case .extends(let type): return "? extends \(describe(type))"
        case .superBound(let type): return "? super \(describe(type))"
        }
    }

    static func erased(_ type: String) -> String {
        String(type.prefix { $0 != "<" })
    }

    /// Where the engine's answer departs from javac's. The buckets are ordered by how much they matter
    /// for completion: a different *erased* type changes which members are offered; differing type
    /// arguments change what the next call in a chain, or a lambda parameter, is typed as.
    static func bucket(javac: String, engine: String?, isTypeReference: Bool) -> String {
        guard let engine else { return "engine: no receiver type" }
        if javac.hasPrefix("<intersection") { return "javac receiver is an intersection type (no location)" }
        let j = simplified(javac)
        let e = simplified(engine)
        if j == e { return "exact" }
        if let bounded = uncaptured(javac), simplified(bounded) == e { return "equal up to capture (engine uses the bound)" }
        let capture = j.contains("CAP#") || j.contains("capture#")
        let intersection = j.contains("INT#")
        let jErased = erased(j)
        let eErased = erased(e)
        if jErased == eErased || (capture && jErased == eErased) {
            if capture { return "same class, javac has a capture variable" }
            if j.replacingOccurrences(of: "?", with: "").count != e.replacingOccurrences(of: "?", with: "").count || j.contains("?") || e.contains("?") {
                return "same class, wildcard arguments differ"
            }
            if e.contains("Object") && !j.contains("Object") { return "same class, engine argument is Object" }
            if e.contains("?") || e.hasPrefix("?") { return "same class, engine argument unresolved" }
            return "same class, type arguments differ"
        }
        if intersection { return "javac receiver is an intersection type" }
        // A type variable has the members of its bound: `V` against `Object`, `T` against `Enum<T>` is the same list.
        if jErased.count <= 3, jErased.first?.isUppercase == true, jErased.allSatisfy({ $0.isLetter || $0.isNumber }), !j.contains("<"),
           !e.hasPrefix("?"), !e.isEmpty {
            return "benign: javac receiver is a type variable (engine reports its bound)"
        }
        if e.contains("?" + "Object") || e.hasPrefix("?") || (e.contains("?") && !e.contains("?extends") && !e.contains("?super") && e.range(of: "\\?[A-Z]", options: .regularExpression) != nil) {
            return "engine type contains an unresolved name"
        }
        if e == "Object" { return "engine reports Object" }
        if capture { return "javac receiver is a capture variable" }
        if isTypeReference { return "different class (type qualifier)" }
        return "different class"
    }

    // MARK: - Run

    static func audit(
        project: JavaCompletionQualityHarness.QualityProject, client: JavaAnalysisServerClient, world: JavaDifferentialHarness.World,
        fileLimit: Int, perFile: Int, markedOnly: Bool = false
    ) async -> [Record] {
        var files: [URL] = []
        for root in project.sourceRoots { files += JavaDifferentialHarness.javaFiles(under: root, limit: Int.max) }
        files = JavaDifferentialHarness.strideSample(Array(Set(files)).sorted { $0.path < $1.path }, count: fileLimit)
        var records: [Record] = []
        let dumpsMembers = ProcessInfo.processInfo.environment["JAVA_AUDIT_MEMBERS"] != nil
        for file in files {
            let resolved = file.resolvingSymlinksInPath()
            guard let text = try? String(contentsOf: resolved, encoding: .utf8), text.utf16.count < 300_000,
                  let tree = JavaSyntaxParser().parse(text), !tree.rootNode.hasError else { continue }
            let probes = probes(in: text, tree: tree, limit: perFile, markedOnly: markedOnly)
            guard !probes.isEmpty else { continue }
            let probed = probedText(text, bytes: tree.sourceBytes, probes: probes)
            guard let diagnostics = try? await client.check(moduleId: project.name, file: resolved, text: probed.text) else { continue }
            let relevant = diagnostics.filter { $0.severity == .error && $0.key.hasPrefix("compiler.err.cant.resolve") && $0.message.contains("zzProbe") }
            for (index, probe) in probes.enumerated() {
                let start = probed.receiverStarts[index]
                guard let diagnostic = relevant.first(where: { $0.start == start }) else { continue }
                // javac leaves out `location:` when the receiver is an intersection type (a lub, or `T extends A & B`).
                let javac = javacType(from: diagnostic.message) ?? "<intersection type: javac prints no location>"
                // The engine, on the original file, caret right after the dot (the name still follows).
                let utf16Dot = String(decoding: tree.sourceBytes[..<(probe.dotByte + 1)], as: UTF8.self).utf16.count
                let caret = JavaDifferentialHarness.position(in: text, utf16: utf16Dot)
                let context = CompletionContext(
                    document: JavaDifferentialHarness.document(url: resolved, text: text, caret: caret),
                    cursor: Cursor(position: caret), trigger: .manual, prefix: "",
                    range: EditorIntelligence.TextRange(start: caret, end: caret)
                )
                let diagnosis = await world.completion.diagnose(context: context)
                let engineType = diagnosis?.receiverType.map(describe)
                let isType = diagnosis?.receiverIsTypeReference ?? false
                // javac prints no location for `this` / `super` / an anonymous class: nothing to compare against.
                let selfLike = ["this", "super"].contains(probe.receiverText) || probe.receiverText.hasSuffix(".this")
                    || probe.receiverText.hasSuffix(".super") || probe.tags.contains("new") && probe.receiverText.contains("{")
                let bucket = javac.hasPrefix("<intersection") && selfLike
                    ? "not compared: this / super / anonymous class (javac prints no location)"
                    : bucket(javac: javac, engine: engineType, isTypeReference: isType)
                var candidates: [String] = []
                if bucket != "exact", !bucket.hasPrefix("same class"), !bucket.hasPrefix("equal up to") {
                    candidates = Array(await world.completion.provide(context: context).prefix(6).map(\.label))
                }
                var record = Record(
                    project: project.name, file: resolved.lastPathComponent, line: probe.line, receiver: probe.receiverText,
                    javac: simplified(javac), engine: engineType.map(simplified) ?? "nil", bucket: bucket,
                    tags: probe.tags + (javac.contains("?") || javac.contains("CAP#") ? ["javac-type-has-wildcard"] : [])
                        + (isType ? ["type-qualifier"] : []),
                    candidates: candidates
                )
                if dumpsMembers, bucket != "exact", !bucket.hasPrefix("not compared") {
                    let items = await world.completion.provide(context: context)
                    record.path = resolved.path
                    record.engineRaw = engineType ?? "nil"
                    let memberItems = items.filter { [.method, .field, .property].contains($0.kind) }
                    record.members = Array(Set(memberItems.map(\.label))).sorted()
                    record.origins = Array(Set(memberItems.map { "\($0.label)@\($0.origin ?? "")" })).sorted()
                    let utf16 = { (byte: Int) in String(decoding: tree.sourceBytes[..<byte], as: UTF8.self).utf16.count }
                    record.receiverUTF16 = [utf16(probe.objectStart), utf16(probe.objectEnd)]
                }
                records.append(record)
            }
        }
        return records
    }

    static func render(_ records: [Record], examples: Int) -> String {
        var out = "RECEIVER TYPE AUDIT — \(records.count) sites\n\n"
        func percent(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.1f%%", 100 * Double(n) / Double(d)) }
        let values = records.filter { !$0.tags.contains("type-qualifier") && !$0.bucket.hasPrefix("not compared") }
        out += "(\(records.filter { $0.bucket.hasPrefix("not compared") }.count) this/super/anonymous receivers are not compared: javac prints no type for them)\n"
        out += "value receivers: \(values.count)   exact \(percent(values.filter { $0.bucket == "exact" }.count, values.count))\n"
        out += "same erased class (value receivers): \(percent(values.filter { $0.bucket == "exact" || $0.bucket.hasPrefix("same class") }.count, values.count))\n\n"
        out += "BY BUCKET (all sites)\n"
        let buckets = Dictionary(grouping: records, by: \.bucket).sorted { $0.value.count > $1.value.count }
        for (name, group) in buckets { out += String(format: "  %6d  %6@  %@\n", group.count, percent(group.count, records.count) as NSString, name) }
        out += "\nBY PROJECT (value receivers; exact / same class / different)\n"
        for (name, group) in Dictionary(grouping: values, by: \.project).sorted(by: { $0.key < $1.key }) {
            let exact = group.filter { $0.bucket == "exact" }.count
            let same = group.filter { $0.bucket.hasPrefix("same class") }.count
            out += "  \(name): n=\(group.count) exact \(percent(exact, group.count)) same-class-only \(percent(same, group.count)) different \(percent(group.count - exact - same, group.count))\n"
        }
        out += "\nBY RECEIVER FEATURE (value receivers: n, exact, same-class-only, different class)\n"
        var tagCounts: [String: [Record]] = [:]
        for record in values { for tag in Set(record.tags) { tagCounts[tag, default: []].append(record) } }
        for (tag, group) in tagCounts.sorted(by: { $0.value.count > $1.value.count }) where group.count >= 5 {
            let exact = group.filter { $0.bucket == "exact" }.count
            let same = group.filter { $0.bucket.hasPrefix("same class") }.count
            out += "  \(tag.padding(toLength: 28, withPad: " ", startingAt: 0)) n=\(String(group.count).padding(toLength: 6, withPad: " ", startingAt: 0)) exact \(percent(exact, group.count).padding(toLength: 7, withPad: " ", startingAt: 0)) same-class \(percent(same, group.count).padding(toLength: 7, withPad: " ", startingAt: 0)) different \(percent(group.count - exact - same, group.count))\n"
        }
        out += "\nEXAMPLES (project/file:line | receiver | javac | engine | tags | engine's first candidates)\n"
        let includeExact = ProcessInfo.processInfo.environment["JAVA_AUDIT_EXACT"] == "1"
        for (name, group) in buckets where name != "exact" || includeExact {
            out += "\n[\(name)] \(group.count)\n"
            for record in group.prefix(examples) {
                out += "  \(record.project)/\(record.file):\(record.line) | \(record.receiver) | javac \(record.javac) | engine \(record.engine) | \(record.tags.joined(separator: ",")) | \(record.candidates.joined(separator: ","))\n"
            }
        }
        return out
    }
}

final class JavaReceiverTypeAuditTests: XCTestCase {
    func testAuditReceiverTypesAgainstJavac() async throws {
        guard ProcessInfo.processInfo.environment["JAVA_AUDIT"] == "1" else { throw XCTSkip("Set JAVA_AUDIT=1 to run the receiver-type audit") }
        let environment = try ParityTestSupport.requireEnvironment()
        let client = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: environment.jarURL, javaExecutable: environment.jdk.home.appendingPathComponent("bin/java"), maxHeapMB: 4096
        ), idleTimeout: .seconds(1800))
        let jdkShard = try JavaDifferentialHarness.writeJDKShard(installation: environment.jdk)
        let set = ProcessInfo.processInfo.environment["JAVA_AUDIT_SET"] ?? "all"
        var projects: [JavaCompletionQualityHarness.QualityProject] = []
        if set == "development" || set == "all" { projects += try JavaCompletionQualityHarness.developmentProjects() }
        if set == "held-out" || set == "all" { projects += try JavaCompletionQualityHarness.heldOutProjects() }
        if let only = ProcessInfo.processInfo.environment["JAVA_AUDIT_ONLY"] {
            let names = Set(only.split(separator: ",").map(String.init))
            projects = projects.filter { names.contains($0.name) }
        }
        if let extra = ProcessInfo.processInfo.environment["JAVA_AUDIT_EXTRA"] {
            // A directory of hand-written probe files; accesses written `receiver/*P*/.member` are probed.
            projects = [JavaCompletionQualityHarness.QualityProject(name: "probes", group: "synthetic", sourceRoots: [URL(fileURLWithPath: extra)], note: "")]
        }
        let markedOnly = ProcessInfo.processInfo.environment["JAVA_AUDIT_EXTRA"] != nil
        let fileLimit = Int(ProcessInfo.processInfo.environment["JAVA_AUDIT_FILES"] ?? "") ?? 30
        let perFile = Int(ProcessInfo.processInfo.environment["JAVA_AUDIT_SITES"] ?? "") ?? 80
        var records: [JavaReceiverTypeAudit.Record] = []
        do {
            for project in projects {
                try await client.configure(JavaAnalysisServerModule(
                    moduleId: project.name, classpath: project.classpath,
                    sourcepath: project.sourceRoots + project.extraSourcepath, processorPath: project.processorPath
                ))
                let world: JavaDifferentialHarness.World
                if let model = project.model {
                    world = try await JavaCompletionQualityHarness.makeModelWorld(model, jdkShard: jdkShard, installation: environment.jdk)
                } else {
                    world = try await JavaDifferentialHarness.makeWorld(sourceRoot: project.sourceRoots[0], jdkShard: jdkShard, installation: environment.jdk)
                }
                records += await JavaReceiverTypeAudit.audit(project: project, client: client, world: world, fileLimit: fileLimit, perFile: perFile, markedOnly: markedOnly)
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
        let examples = Int(ProcessInfo.processInfo.environment["JAVA_AUDIT_EXAMPLES"] ?? "") ?? 12
        let report = JavaReceiverTypeAudit.render(records, examples: examples)
        print(report)
        if let path = ProcessInfo.processInfo.environment["JAVA_AUDIT_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = ProcessInfo.processInfo.environment["JAVA_AUDIT_MEMBERS"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var lines: [String] = []
            for record in records {
                guard let file = record.path, let raw = record.engineRaw, let members = record.members, let range = record.receiverUTF16 else { continue }
                let dump = JavaReceiverTypeAudit.MemberDump(
                    project: record.project, path: file, line: record.line, receiver: record.receiver, receiverUTF16: range,
                    javac: record.javac, engine: record.engine, engineRaw: raw, bucket: record.bucket, members: members,
                    origins: record.origins ?? []
                )
                lines.append(String(decoding: try encoder.encode(dump), as: UTF8.self))
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            let projectLines = try projects.map { project in
                String(decoding: try encoder.encode(JavaReceiverTypeAudit.ProjectDump(
                    project: project.name, classpath: project.classpath.map(\.path),
                    sourcepath: (project.sourceRoots + project.extraSourcepath).map(\.path)
                )), as: UTF8.self)
            }
            try (projectLines.joined(separator: "\n") + "\n").write(toFile: path + ".projects", atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(records.count, 0)
    }
}
