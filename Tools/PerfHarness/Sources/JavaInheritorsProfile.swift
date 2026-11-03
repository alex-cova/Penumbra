import Foundation
import JavaIntelligence

/// Release-mode cost of "what extends X" over a project (F15): the inheritor table against the scan
/// it replaces (decode every project class, compute a supertype closure for each).
///
///   swift run -c release PerfHarness java-inheritors synthetic [--files N]
///
/// `files` classes spread over 50 interfaces; every tenth class extends an earlier class instead,
/// so the answer is transitive. The table's first query includes its build (cold); later ones are
/// warm. Prints the number of subtypes so the two approaches can be seen to agree.
enum JavaInheritorsProfile {
    private static let interfaceCount = 50

    static func run(files: Int) throws {
        try runBlocking { try await measure(files: files) }
    }

    private static func ref(_ name: String) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: [], outer: nil)
    }

    private static func measure(files: Int) async throws {
        note("=== java inheritors (synthetic, \(files) classes, \(interfaceCount) interfaces) ===")
        var stubs: [JavaClassStub] = []
        for k in 0..<interfaceCount {
            stubs.append(JavaClassStub(
                binaryName: "app.I\(k)", qualifiedName: "app.I\(k)", simpleName: "I\(k)", packageName: "app",
                kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag], origin: .jdkModule("synthetic")
            ))
        }
        for i in 0..<files {
            let name = "app.sub\(i % 40).C\(i)"
            let package = "app.sub\(i % 40)"
            let chained = i % 10 == 9 && i > 10
            stubs.append(JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: "C\(i)", packageName: package, kind: .classKind,
                modifiers: [.publicFlag],
                superclass: chained ? ref("app.sub\((i - 5) % 40).C\(i - 5)") : nil,
                interfaces: chained ? [] : [ref("app.I\(i % interfaceCount)")],
                origin: .jdkModule("synthetic")
            ))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-inheritors-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: url) }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: url))])

        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        let coldStart = clock.now
        let first = await index.projectSubtypes(of: "app.I0")
        let coldSeconds = seconds(clock.now - coldStart)

        var warm: [Double] = []
        for k in 0..<interfaceCount {
            let start = clock.now
            _ = await index.projectSubtypes(of: "app.I\(k)")
            warm.append(seconds(clock.now - start))
        }
        warm.sort()

        // The scan it replaces: decode every project class, then a closure per class with supertypes.
        let scanStart = clock.now
        var scanned = 0
        for stub in await index.projectClassStubs() where stub.qualifiedName != "app.I0" {
            let closure: Set<String> = stub.superclass == nil && stub.interfaces.isEmpty
                ? [stub.qualifiedName]
                : await JavaMemberLookup.supertypeClosure(of: stub.qualifiedName, index: index)
            if closure.contains("app.I0") { scanned += 1 }
        }
        let scanSeconds = seconds(clock.now - scanStart)

        print("metric,classes,seconds,extra")
        print("inheritors_cold_first_query,\(files),\(String(format: "%.6f", coldSeconds)),subtypes=\(first.count)")
        print("inheritors_warm_median,\(files),\(String(format: "%.6f", warm[warm.count / 2])),p90=\(String(format: "%.6f", warm[warm.count * 9 / 10]))")
        print("closure_scan_one_interface,\(files),\(String(format: "%.6f", scanSeconds)),subtypes=\(scanned)")
        note(String(format: "  table cold %.2f ms, warm median %.3f ms, closure scan %.2f ms; agree: %@",
                    coldSeconds * 1000, warm[warm.count / 2] * 1000, scanSeconds * 1000, first.count == scanned ? "yes" : "NO"))
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let box = InheritorsBlockingBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await body() } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }
}

private final class InheritorsBlockingBox: @unchecked Sendable {
    var error: Error?
}
