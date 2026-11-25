#!/usr/bin/env python3
"""Compile the log components in isolation and measure before/after RSS with real pipes."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

BENCHMARK = r"""
import Foundation

private final class OriginalConsole: @unchecked Sendable {
    private var console = IDEProjectConsoleLog()
    func append(_ line: GradleOutputLine) {
        console.appendProcessLine(IDEProjectOutputLine(stream: .stdout, text: line.text))
    }
    var count: Int { console.totalLineCount }
}

@main
struct LogBenchmark {
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let size = Int(CommandLine.arguments[2])! * 1024 * 1024
        let line = String(repeating: "x", count: 255)
        let command = size == 0 ? ":" : "/usr/bin/yes " + line + " | /usr/bin/head -c " + String(size)
        let request = SubprocessRequest(executable: "/bin/sh", arguments: ["-c", command])
        let clock = ContinuousClock.now
        if mode == "baseline" {
            let console = OriginalConsole()
            let splitter = OriginalGradleOutputLineSplitter(handler: console.append)
            let result = try await SubprocessRunner.run(request) { data, _ in
                splitter.append(data, stream: .stdout)
            }
            splitter.flush()
            let text = String(decoding: result.stdout.data, as: UTF8.self)
            print("bytes=\(text.utf8.count) lines=\(console.count) elapsed=\(clock.duration(to: .now))")
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-bench-\(UUID())")
            let log = try GradleSessionLog(directory: directory, removeOnClose: true)
            let splitter = GradleOutputLineSplitter(handler: { _ in })
            _ = try await SubprocessRunner.runStreaming(request) { data, source in
                let stream: GradleOutputLine.Stream = source == .stdout ? .stdout : .stderr
                try log.append(data, stream: stream)
                splitter.append(data, stream: stream)
            }
            splitter.flush()
            print("bytes=\(log.snapshot.bytes) records=\(log.snapshot.records) elapsed=\(clock.duration(to: .now))")
            precondition(log.snapshot.bytes == UInt64(size))
            let exported = directory.appendingPathComponent("export")
            try log.export(to: exported)
            let handle = try FileHandle(forReadingFrom: exported)
            defer { try? handle.close() }
            let block = Data(String(repeating: line + "\n", count: 4096).utf8)
            var checked = 0
            while checked < size {
                checked += try autoreleasepool {
                    guard let bytes = try handle.read(upToCount: block.count), !bytes.isEmpty else {
                        preconditionFailure("Export ended before the producer's byte count")
                    }
                    precondition(bytes == block.prefix(bytes.count))
                    return bytes.count
                }
            }
            precondition(checked == size)
            print("verified=\(checked)")
        }
    }
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="763fc47e", help="Git ref before disk-backed Gradle console")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    runner = "Sources/JavaIntelligence/Gradle/GradleCommandRunner.swift"
    console = "Umbra/Sources/Umbra/Projects/IDEProjectConsoleLog.swift"

    def old(path):
        return subprocess.check_output(["git", "show", f"{args.baseline}:{path}"], text=True)

    with tempfile.TemporaryDirectory(prefix="umbra-log-benchmark-") as scratch:
        directory = Path(scratch)
        old_splitter = old(runner).split("final class GradleOutputLineSplitter", 1)[1]
        (directory / "Original.swift").write_text(
            "import Foundation\nfinal class OriginalGradleOutputLineSplitter" + old_splitter, encoding="utf-8"
        )
        current = Path(runner).read_text()
        types = current[current.index("public struct GradleOutputLine"):current.index("public enum GradleCommandError")]
        splitter = current[current.index("final class GradleOutputLineSplitter"):]
        (directory / "Current.swift").write_text("import Foundation\n" + types + splitter, encoding="utf-8")
        (directory / "Console.swift").write_text(old(console), encoding="utf-8")
        (directory / "Benchmark.swift").write_text(BENCHMARK, encoding="utf-8")
        binary = directory / "bench"
        subprocess.run([
            "swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(directory / "modules"),
            *map(str, sorted(directory.glob("*.swift"))), "Sources/JavaIntelligence/Gradle/GradleSessionLog.swift",
            *map(str, sorted(Path("Packages/SubprocessKit/Sources/SubprocessKit").glob("*.swift"))),
            "-o", str(binary)
        ], check=True)
        for mode, sizes in (("baseline", (0, 1, 10, 100)), ("stream", (0, 1, 10, 100, 500, 1024))):
            for size in sizes:
                print(f"{mode} input: {size} MiB", flush=True)
                subprocess.run(["/usr/bin/time", "-l", str(binary), mode, str(size)], check=True)


if __name__ == "__main__":
    main()
