import Foundation
import SubprocessKit
import SwiftIntelligence

/// A tool of the toolchain a project is built with.
struct IDESwiftUIPreviewToolchain: Sendable, Equatable {
    var swift: String
    var swiftc: String

    func executable(for tool: SwiftPreviewCommand.Tool) -> String {
        switch tool {
        case .swift: return swift
        case .swiftc: return swiftc
        case .nm: return "/usr/bin/nm"
        }
    }

    /// `swiftc` sits beside `swift`, in the toolchain's `bin` directory, or is the `/usr/bin` shim.
    static func beside(swift: String) -> IDESwiftUIPreviewToolchain {
        let sibling = URL(fileURLWithPath: swift).deletingLastPathComponent().appendingPathComponent("swiftc").path
        let swiftc = FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "/usr/bin/swiftc"
        return IDESwiftUIPreviewToolchain(swift: swift, swiftc: swiftc)
    }
}

struct IDESwiftUIPreviewRunResult: Sendable, Equatable {
    var status: Int32
    var output: String
    var cancelled: Bool

    var succeeded: Bool { status == 0 && !cancelled }
}

/// A running host process.
protocol IDESwiftUIPreviewHostProcess: AnyObject, Sendable {
    func terminate()
}

/// How the session runs things. The real one is SubprocessKit; tests substitute a fake that
/// records the commands and writes the files a build would leave.
protocol IDESwiftUIPreviewProcessRunning: Sendable {
    /// Runs one command to its end and returns its merged output. Cancelling the calling task stops it.
    func run(
        executable: String, arguments: [String], workingDirectory: URL?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> IDESwiftUIPreviewRunResult

    /// Starts the host and returns at once.
    func startHost(
        executable: String, arguments: [String], workingDirectory: URL?,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any IDESwiftUIPreviewHostProcess
}

struct IDESwiftUIPreviewSubprocessRunner: IDESwiftUIPreviewProcessRunning {
    private final class Host: IDESwiftUIPreviewHostProcess, @unchecked Sendable {
        let handle: SubprocessHandle
        init(_ handle: SubprocessHandle) { self.handle = handle }
        func terminate() { handle.terminate() }
    }

    func run(
        executable: String, arguments: [String], workingDirectory: URL?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> IDESwiftUIPreviewRunResult {
        var request = SubprocessRequest(executable: executable, arguments: arguments)
        request.workingDirectory = workingDirectory
        request.output = .merged
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = nil
        do {
            let result = try await SubprocessRunner.run(request) { data, _ in
                onOutput(String(decoding: data, as: UTF8.self))
            }
            return IDESwiftUIPreviewRunResult(
                status: result.exit.status, output: result.stdout.text, cancelled: result.cancelled || Task.isCancelled
            )
        } catch {
            return IDESwiftUIPreviewRunResult(status: 127, output: "\(error)", cancelled: Task.isCancelled)
        }
    }

    func startHost(
        executable: String, arguments: [String], workingDirectory: URL?,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any IDESwiftUIPreviewHostProcess {
        var request = SubprocessRequest(executable: executable, arguments: arguments)
        request.workingDirectory = workingDirectory
        request.output = .merged
        request.stdoutCapture = .discard
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = nil
        let handle = try SubprocessRunner.start(request) { data, _ in
            onOutput(String(decoding: data, as: UTF8.self))
        }
        return Host(handle)
    }
}
