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
    case customMissing(String)

    var message: String {
        switch self {
        case .notInstalled(let name): "The \(name) adapter is not installed. Install it in Settings ▸ Agent ▸ Adapters."
        case .nodeMissing: "Node.js was not found, and this adapter needs it. Install Node.js 22 or later."
        case .cliMissing(let command): "Could not find “\(command)” on PATH."
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
        systemPackageName: (String) -> String? = IDEACPLaunchResolver.packageName(ofExecutable:)
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
            let probe = IDEACPDefinition(name: entry.name, command: command, args: args)
            guard let path = probe.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable) else {
                return .unavailable(.cliMissing(command))
            }
            return .launch(IDEACPResolvedLaunch(
                executable: path, args: args, source: .nativeCLI, identity: identity, managed: nil))

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
