import Darwin
import Foundation

/// A started child and the parent's ends of its pipes.
struct SpawnedProcess {
    var pid: pid_t
    var stdoutFD: Int32
    /// `nil` when stderr was merged into stdout.
    var stderrFD: Int32?
    /// `nil` when stdin is `/dev/null`.
    var stdinFD: Int32?
}

enum Subprocess {
    /// `posix_spawn` with exactly the descriptors the request asks for: `CLOEXEC_DEFAULT` closes
    /// everything else at exec, so a child never holds another run's pipe open.
    static func spawn(_ request: SubprocessRequest) throws -> SpawnedProcess {
        var opened: [Int32] = []
        func closeAll() { opened.forEach { close($0) } }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw SubprocessError.pipeFailed(errno: errno) }
            opened.append(contentsOf: fds)
            // Close-on-exec in the parent too, so a child spawned meanwhile by other code cannot inherit it.
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        do {
            let stdout = try makePipe()
            let stderr = request.output == .merged ? nil : try makePipe()
            var stdin: (read: Int32, write: Int32)?
            switch request.standardInput {
            case .data, .interactive: stdin = try makePipe()
            case .closed: break
            }

            var actions: posix_spawn_file_actions_t? = nil
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            if let stdin {
                try check(posix_spawn_file_actions_adddup2(&actions, stdin.read, 0))
            } else {
                try check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
            }
            try check(posix_spawn_file_actions_adddup2(&actions, stdout.write, 1))
            try check(posix_spawn_file_actions_adddup2(&actions, (stderr ?? stdout).write, 2))
            if let directory = request.workingDirectory {
                // The `_np` spelling: the plain one needs a newer SDK than this package's macOS 14.
                try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
            }

            var attributes: posix_spawnattr_t? = nil
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            if request.processGroup { flags |= POSIX_SPAWN_SETPGROUP }
            try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
            // A child starts with default signal handling and nothing blocked, whatever this process
            // (or the thread that spawns) ignores or blocks: an inherited SIG_IGN on SIGTERM would
            // make the child unkillable except by SIGKILL, and an ignored SIGPIPE changes how
            // pipelines end.
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            try check(posix_spawnattr_setsigdefault(&attributes, &everySignal))
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            try check(posix_spawnattr_setsigmask(&attributes, &noSignals))
            if request.processGroup { try check(posix_spawnattr_setpgroup(&attributes, 0)) }

            let arguments = [request.executable] + request.arguments
            let environment = (request.environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }

            var pid: pid_t = 0
            let status = posix_spawn(&pid, request.executable, &actions, &attributes, argv, envp)
            guard status == 0 else { throw SubprocessError.launchFailed(errno: status) }

            // The child holds its own ends now; ours must go, or the reader never sees EOF.
            close(stdout.write)
            if let stderr { close(stderr.write) }
            if let stdin { close(stdin.read) }
            return SpawnedProcess(pid: pid, stdoutFD: stdout.read, stderrFD: stderr?.read, stdinFD: stdin?.write)
        } catch {
            closeAll()
            throw error
        }
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw SubprocessError.launchFailed(errno: status) }
    }
}
