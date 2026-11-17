import Foundation
import SubprocessKit

/// The first line a server prints for its version flag, read once for Settings. Bounded in output and
/// time, and only for specs that declare a version argument.
enum IDEServerVersion {
    static func read(spec: IDELanguageServerSpec, executable: URL, environment: [String: String]?) async -> String? {
        guard let arguments = spec.versionArguments else { return nil }
        var request = SubprocessRequest(executable: executable.path, arguments: arguments)
        request.stdoutCapture = .bounded(head: 2_048, tail: 0)
        request.stderrCapture = .discard
        request.timeout = .seconds(4)
        request.environment = environment
        guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded else { return nil }
        return firstLine(result.stdout.text)
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(120))
    }
}
