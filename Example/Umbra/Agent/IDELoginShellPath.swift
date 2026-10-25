import Foundation
import SubprocessKit

/// The `PATH` a login shell would give the user (sdkman, asdf, mise, Homebrew on a custom prefix…).
/// A GUI app's own `PATH` is minimal, so `AgentCommandEnvironment` adds these entries, and only
/// these: the rest of a login environment can hold credentials a model-driven command should not see.
///
/// Asked once per process. A shell that fails or takes too long yields no entries, and is not asked again.
actor IDELoginShellPath {
    static let shared = IDELoginShellPath()

    /// Prints the login shell's `PATH` and nothing else, so a noisy profile cannot change the result.
    typealias Reader = @Sendable () async -> String?

    private let reader: Reader
    private var cached: [String]?
    private var inFlight: Task<[String], Never>?

    init(reader: @escaping Reader = IDELoginShellPath.readFromZsh) {
        self.reader = reader
    }

    func entries() async -> [String] {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let reader = reader
        let task = Task { Self.parse(await reader()) }
        inFlight = task
        let entries = await task.value
        cached = entries
        inFlight = nil
        return entries
    }

    /// Starts the read without waiting for it, so the first command does not pay for zsh's startup.
    func warm() {
        guard cached == nil, inFlight == nil else { return }
        Task { _ = await entries() }
    }

    /// Absolute entries only, in order, without repeats. A directory that is gone is dropped.
    static func parse(_ output: String?, directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard let output else { return [] }
        // A profile can print before the marker; the PATH is what follows the last one.
        let value = output.components(separatedBy: marker).last ?? output
        var seen = Set<String>()
        return value.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && directoryExists($0) && seen.insert($0).inserted }
    }

    private static let marker = "__UMBRA_PATH__"

    @Sendable
    static func readFromZsh() async -> String? {
        var request = SubprocessRequest(
            executable: "/bin/zsh", arguments: ["-lc", "printf '%s%s' '\(marker)' \"$PATH\""])
        request.environment = [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8", "TERM": "dumb",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = .seconds(3)
        request.terminationGrace = .zero
        guard let result = try? await SubprocessRunner.run(request),
              !result.timedOut, !result.cancelled, result.exit.exitCode == 0
        else { return nil }
        return result.stdout.text
    }
}
