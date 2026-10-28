import Foundation

/// The `xctrace` commands behind Profile for a Swift program: record a launch with the Time Profiler template, then
/// export its `time-profile` table as XML (`XCTraceTimeProfileParser` reads it). Pure: nothing here starts a process.
public enum SwiftProfileCommand {
    public static let template = "Time Profiler"

    /// `xcrun xctrace record --template 'Time Profiler' --output <trace> --launch -- <executable> <arguments…>`.
    /// A launched program is recorded until it exits.
    public static func recordArguments(trace: URL, executable: URL, arguments: [String] = [], timeLimit: String? = nil) -> [String] {
        var result = ["xctrace", "record", "--template", template, "--output", trace.path]
        if let timeLimit { result += ["--time-limit", timeLimit] }
        result += ["--launch", "--", executable.path] + arguments
        return result
    }

    /// The table of the sampled stacks, in the recording's first run.
    public static let timeProfileXPath = #"/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]"#

    /// `xcrun xctrace export --input <trace> --xpath … --output <xml>`.
    public static func exportArguments(trace: URL, output: URL) -> [String] {
        ["xctrace", "export", "--input", trace.path, "--xpath", timeProfileXPath, "--output", output.path]
    }

    /// Whether `url` is an Instruments recording: a `.trace` package.
    public static func isTraceRecording(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "trace"
    }
}
