import Foundation

/// The one switch for tests that call OpenAI, Anthropic or an Ollama server (the smoke tests and the
/// evals). Such a test runs only when
///
/// 1. it is **not** running under CI (`CI` or `GITHUB_ACTIONS` is set to anything but empty or `false`),
///    whatever else is set, so a secret wired into a workflow by mistake cannot start one, and
/// 2. its variable has a value: an empty string counts as unset, because a workflow that passes
///    `${{ secrets.MISSING }}` hands the test an empty variable.
///
/// `swift test` with none of the variables set calls nothing.
enum PaidTests {
    static let environment = ProcessInfo.processInfo.environment

    /// Running under GitHub Actions or another CI system.
    static func isCI(_ environment: [String: String]) -> Bool {
        ["CI", "GITHUB_ACTIONS"].contains { name in
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
            return !value.isEmpty && value != "false" && value != "0"
        }
    }

    /// The variable's value, or `nil` when it is unset, empty, or this is CI.
    static func value(_ variable: String, in environment: [String: String]) -> String? {
        guard !isCI(environment),
              let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    static var isCI: Bool { isCI(environment) }
    static func value(_ variable: String) -> String? { value(variable, in: environment) }
    static func allowed(_ variable: String) -> Bool { value(variable) != nil }
}
