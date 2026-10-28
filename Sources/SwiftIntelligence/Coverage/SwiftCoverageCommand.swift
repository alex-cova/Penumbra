import Foundation

/// The `swift test` commands behind Run Tests with Coverage for a SwiftPM package: run the tests with the
/// compiler's coverage instrumentation on, then ask SwiftPM where it left the `llvm-cov export` JSON
/// (`LLVMCoverageJSONParser` reads it). Pure: nothing here starts a process.
public enum SwiftCoverageCommand {
    /// `swift test` with coverage on. `filters` are `--filter` patterns, `xunitOutput` the report path.
    public static func testArguments(filters: [String] = [], xunitOutput: String? = nil) -> [String] {
        var arguments = ["test", "--enable-code-coverage"]
        for filter in filters { arguments += ["--filter", filter] }
        if let xunitOutput { arguments += ["--xunit-output", xunitOutput] }
        return arguments
    }

    /// Prints the path of the JSON after a coverage run (it does not run the tests).
    public static let codecovPathArguments = ["test", "--show-codecov-path"]

    /// The JSON path in `swift test --show-codecov-path`'s output: its last line that names a `.json` file. Anything
    /// printed before it (a build log, a warning) is ignored.
    public static func codecovPath(fromOutput output: String) -> URL? {
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasSuffix(".json") && $0.hasPrefix("/") }
        return line.map { URL(fileURLWithPath: $0) }
    }
}
