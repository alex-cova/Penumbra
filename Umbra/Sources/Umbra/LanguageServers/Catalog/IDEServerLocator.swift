import Foundation
import SubprocessKit

/// Finds a server binary. A GUI app does not inherit the shell's `PATH`, so the search is: the user's
/// override, the project's own copy, the process `PATH`, the login shell's `PATH` (asked once and cached),
/// then the install directories each toolchain uses. Pure lookups take their inputs as arguments so
/// tests run without a real toolchain.
enum IDEServerLocator {
    static let homebrewDirectories = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]

    static func locate(
        spec: IDELanguageServerSpec,
        root: URL,
        override: String?,
        searchPath: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let override, !override.isEmpty {
            // A configured path that does not run is an error to show, not a reason to quietly use another binary.
            return isExecutable(override) ? URL(fileURLWithPath: override) : nil
        }
        for relative in spec.projectLocalPaths {
            let path = root.appendingPathComponent(relative).path
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        let extras = spec.extraSearchDirectories.map { expand($0, home: home) }
        for directory in searchPath + homebrewDirectories + extras where !directory.isEmpty {
            for name in spec.executables {
                let path = (directory as NSString).appendingPathComponent(name)
                if isExecutable(path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    static func expand(_ path: String, home: URL) -> String {
        path.hasPrefix("~") ? home.path + path.dropFirst() : path
    }

    static func pathEntries(_ value: String?) -> [String] {
        (value ?? "").split(separator: ":").map(String.init)
    }

    /// The `PATH` an interactive login shell would have, read once per launch of the app. Empty when the
    /// shell does not answer within the bounded capture.
    static func loginShellPath() async -> [String] {
        await LoginShellPathCache.shared.value()
    }

    /// Environment for the child: the process one with the search path made visible, so a launcher script
    /// (`kotlin-lsp.sh`, `metals`) finds its `java`, `dotnet` or `node`.
    static func environment(base: [String: String], searchPath: [String], extraDirectories: [String]) -> [String: String] {
        var env = base
        var seen = Set<String>()
        let merged = (pathEntries(base["PATH"]) + searchPath + homebrewDirectories + extraDirectories).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }
}

private actor LoginShellPathCache {
    static let shared = LoginShellPathCache()
    private var cached: [String]?

    func value() async -> [String] {
        if let cached { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var request = SubprocessRequest(executable: shell, arguments: ["-l", "-i", "-c", "printf %s \"$PATH\""])
        request.stdoutCapture = .bounded(head: 16_384, tail: 0)
        request.stderrCapture = .discard
        request.timeout = .seconds(5)
        var entries: [String] = []
        if let result = try? await SubprocessRunner.run(request), result.exit.succeeded {
            // Interactive shells may print banners first; PATH is the last line.
            let last = result.stdout.text.split(separator: "\n").last.map(String.init)
            entries = IDEServerLocator.pathEntries(last)
        }
        cached = entries
        return entries
    }
}
