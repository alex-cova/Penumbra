import Foundation

/// A concrete command line for one agent process, and where it came from.
struct IDEACPResolvedLaunch: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The user's own executable (`launchMode == .custom`).
        case custom
        /// An adapter Umbra installed.
        case managed(adapterID: String, version: String)
        /// An adapter found on `PATH` whose package was checked to be the expected one.
        case systemAdapter
        /// An agent CLI's documented ACP mode.
        case nativeCLI
    }

    var executable: String
    var args: [String]
    var source: Source
    /// What a saved remote session id belongs to. It does not change when a managed adapter is
    /// updated, so activating a new version does not restart or reset a live chat.
    var identity: String
    var managed: IDEACPActiveInstall?

    var version: String? {
        if case .managed(_, let version) = source { return version }
        return nil
    }

    var sourceTitle: String {
        switch source {
        case .custom: "Custom executable"
        case .managed(_, let version): "Managed by Umbra · \(version)"
        case .systemAdapter: "System adapter"
        case .nativeCLI: "Native ACP CLI"
        }
    }

    var commandLine: String { ([executable] + args).joined(separator: " ") }
}

enum IDEACPLaunchUnavailable: Equatable, Sendable {
    /// A managed adapter that is not installed, with no verified system copy.
    case notInstalled(String)
    /// A managed adapter is installed but no Node.js can run it.
    case nodeMissing
    /// The agent's CLI is not on `PATH`.
    case cliMissing(String)
    /// A file with the CLI's name was found but is another program (a generic name such as `agent`).
    case cliUnverified(command: String, path: String, agent: String)
    case customMissing(String)

    var message: String {
        switch self {
        case .notInstalled(let name): "The \(name) adapter is not installed. Install it in Settings ▸ Agent ▸ Adapters."
        case .nodeMissing: "Node.js was not found, and this adapter needs it. Install Node.js 22 or later."
        case .cliMissing(let command): "Could not find “\(command)” on PATH."
        case .cliUnverified(let command, let path, let agent):
            "Found “\(command)” at \(path), but it is not \(agent)’s CLI, so Umbra will not run it. Install \(agent)’s CLI, or set the full path to it in Settings ▸ Agent."
        case .customMissing(let message): message
        }
    }
}

enum IDEACPLaunchResolver {
    enum Resolution: Equatable, Sendable {
        case launch(IDEACPResolvedLaunch)
        case unavailable(IDEACPLaunchUnavailable)

        var launch: IDEACPResolvedLaunch? {
            if case .launch(let launch) = self { return launch }
            return nil
        }
    }

    /// Priority: 1) a custom executable the user configured, 2) the active managed adapter,
    /// 3) a system adapter whose package is the expected one, 4) the agent CLI's own ACP mode.
    /// Pure and side-effect free: nothing is downloaded or started, and `npx` is never produced.
    static func resolve(
        definition: IDEACPDefinition,
        entry: IDEACPAdapterEntry?,
        active: IDEACPActiveInstall?,
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        systemPackageName: (String) -> String? = IDEACPLaunchResolver.packageName(ofExecutable:),
        resolvedPath: (String) -> String = IDEACPLaunchResolver.resolvingSymlinks,
        home: String = NSHomeDirectory()
    ) -> Resolution {
        if definition.launchMode == .custom || entry == nil {
            guard let path = definition.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable) else {
                return .unavailable(.customMissing(definition.missingExecutableMessage))
            }
            return .launch(IDEACPResolvedLaunch(
                executable: path, args: definition.args, source: .custom,
                identity: "custom:\(definition.commandLine)", managed: nil))
        }
        guard let entry else { return .unavailable(.customMissing(definition.missingExecutableMessage)) }
        let identity = "adapter:\(entry.id)"

        switch entry.kind {
        case .custom:
            return .unavailable(.customMissing(definition.missingExecutableMessage))

        case .nativeCLI(let command, let args):
            switch findNativeCLI(
                entry: entry, command: command, pathValue: pathValue, home: home,
                isExecutable: isExecutable, resolvedPath: resolvedPath)
            {
            case .found(let path):
                return .launch(IDEACPResolvedLaunch(
                    executable: path, args: args, source: .nativeCLI, identity: identity, managed: nil))
            case .rejected(let name, let path):
                return .unavailable(.cliUnverified(command: name, path: path, agent: entry.name))
            case .missing:
                return .unavailable(.cliMissing(command))
            }

        case .npmPackage(let source):
            if let active {
                let node = isExecutable(active.nodePath)
                    ? active.nodePath
                    : IDEACPNodeRuntime.locateNode(pathValue: pathValue, isExecutable: isExecutable)
                guard let node else { return .unavailable(.nodeMissing) }
                return .launch(IDEACPResolvedLaunch(
                    executable: node, args: [active.entryURL.path],
                    source: .managed(adapterID: entry.id, version: active.version),
                    identity: identity, managed: active))
            }
            if let command = entry.systemCommand {
                let probe = IDEACPDefinition(name: entry.name, command: command)
                if let path = probe.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable),
                   systemPackageName(path) == source.package
                {
                    return .launch(IDEACPResolvedLaunch(
                        executable: path, args: [], source: .systemAdapter, identity: identity, managed: nil))
                }
            }
            return .unavailable(.notInstalled(entry.name))
        }
    }

    enum NativeSearch: Equatable {
        case found(String)
        /// The first file that had a candidate's name but failed the identity check.
        case rejected(name: String, path: String)
        case missing
    }

    /// Looks for a native CLI under each of its names, in `PATH` order and then in the entry's extra
    /// folders. Only the filesystem is read: nothing is started. With an identity check, a file that
    /// is another program is skipped and the search goes on, so Cursor's `agent` later on `PATH` is
    /// found past Grok's.
    static func findNativeCLI(
        entry: IDEACPAdapterEntry, command: String, pathValue: String, home: String,
        isExecutable: (String) -> Bool, resolvedPath: (String) -> String
    ) -> NativeSearch {
        var directories: [String] = []
        for directory in pathValue.split(separator: ":").map(String.init) + entry.extraSearchDirectories.map({ expand($0, home: home) })
        where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        var rejected: NativeSearch?
        for name in [command] + entry.alternateCommands {
            for directory in directories {
                let candidate = "\(directory)/\(name)"
                guard isExecutable(candidate) else { continue }
                guard let check = entry.executableIdentity else { return .found(candidate) }
                if check.accepts(resolvedPath: resolvedPath(candidate)) { return .found(candidate) }
                if rejected == nil { rejected = .rejected(name: name, path: candidate) }
            }
        }
        return rejected ?? .missing
    }

    static func expand(_ directory: String, home: String) -> String {
        if directory == "~" { return home }
        if directory.hasPrefix("~/") { return home + directory.dropFirst() }
        return directory
    }

    static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The `name` in the `package.json` that holds `path` (after following links), looked for in
    /// the few folders above it. A `claude-agent-acp` that is some other program has another name.
    static func packageName(ofExecutable path: String) -> String? {
        var directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let manifest = directory.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["name"] as? String
            {
                return name
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
