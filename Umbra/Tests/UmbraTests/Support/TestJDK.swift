import Foundation

/// Lightweight, test-only JDK discovery (independent of `JDKLocator`, which this helps validate)
/// used to gate integration tests that need a real installed JDK. Machines without one skip those
/// tests via `XCTSkip` rather than failing.
enum TestJDK {
    struct Found {
        let home: URL
        var ctSym: URL { home.appendingPathComponent("lib/ct.sym") }
        var jmodsDir: URL { home.appendingPathComponent("jmods") }
        var release: URL { home.appendingPathComponent("release") }
    }

    static let discovered: Found? = {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], !home.isEmpty {
            let url = URL(fileURLWithPath: home)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("lib/ct.sym").path) {
                return Found(home: url)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            return Found(home: URL(fileURLWithPath: path))
        } catch {
            return nil
        }
    }()
}
