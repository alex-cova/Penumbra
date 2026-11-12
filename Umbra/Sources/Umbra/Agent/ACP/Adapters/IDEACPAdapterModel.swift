import Foundation

// MARK: - Errors

/// Why an adapter operation stopped. Every case has a message the user can act on.
enum IDEACPAdapterError: Error, Equatable, Sendable, LocalizedError {
    case offline(String)
    case registry(String)
    case untrusted(String)
    case integrity(String)
    case unsupportedPlatform(String)
    case nodeMissing
    case nodeTooOld(found: String, required: String)
    case diskFull(needed: Int64, free: Int64)
    case npmFailed(String)
    case cancelled
    case inUse(String)
    case corruptManifest(String)
    case unsafeTree(String)
    case permission(String)
    case startupFailed(String)
    case sandboxed
    case notManaged
    case noPreviousVersion

    var errorDescription: String? {
        switch self {
        case .offline(let detail):
            return "Umbra could not reach the npm registry. Check the network connection and try again. \(detail)"
        case .registry(let detail):
            return "The npm registry answered with something Umbra cannot use. \(detail)"
        case .untrusted(let reason):
            return "Authenticity could not be established, so nothing was installed. \(reason)"
        case .integrity(let detail):
            return "The downloaded package did not match what was verified, so it was discarded. \(detail)"
        case .unsupportedPlatform(let detail):
            return "This adapter does not support this Mac. \(detail)"
        case .nodeMissing:
            return "Node.js was not found. Install Node.js 22 or later (for example with Homebrew: brew install node), then try again."
        case .nodeTooOld(let found, let required):
            return "Node.js \(found) is too old. This adapter needs \(required). Update Node.js and try again."
        case .diskFull(let needed, let free):
            return "Not enough free disk space: about \(Self.format(needed)) are needed and \(Self.format(free)) are free."
        case .npmFailed(let tail):
            return "npm could not finish the install. \(tail)"
        case .cancelled:
            return "The installation was cancelled. Nothing was changed."
        case .inUse(let detail):
            return "That version is in use by a running agent. \(detail)"
        case .corruptManifest(let detail):
            return "An adapter manifest is damaged. \(detail)"
        case .unsafeTree(let path):
            return "The package contains something unsafe (\(path)), so it was discarded."
        case .permission(let detail):
            return "Umbra's adapter folder has unexpected ownership or permissions. \(detail)"
        case .startupFailed(let detail):
            return "The adapter installed but did not start as an ACP agent, so it was not activated. \(detail)"
        case .sandboxed:
            return "Managed installs are not available in the App Store build, which cannot run npm. Use a custom executable instead."
        case .notManaged:
            return "This agent is not installed by Umbra."
        case .noPreviousVersion:
            return "There is no earlier verified version to restore."
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Phase

/// Where an adapter is in its life. The installer drives the working phases forward only.
enum IDEACPAdapterStep: Int, Equatable, Sendable, Comparable {
    case resolving, downloading, verifying, installing

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .resolving: "Resolving"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .installing: "Installing"
        }
    }
}

enum IDEACPAdapterPhase: Equatable, Sendable {
    case notInstalled
    case working(IDEACPAdapterStep)
    case ready(version: String)
    case updateAvailable(installed: String, available: String, security: Bool)
    case updating(from: String, to: String, step: IDEACPAdapterStep)
    /// `keeping` is the version still active, if any: a failed update never removes it.
    case failed(IDEACPAdapterError, keeping: String?)
    case disabled(installed: String?)

    var isBusy: Bool {
        switch self {
        case .working, .updating: true
        default: false
        }
    }

    var installedVersion: String? {
        switch self {
        case .ready(let version): version
        case .updateAvailable(let installed, _, _): installed
        case .updating(let from, _, _): from
        case .failed(_, let keeping): keeping
        case .disabled(let installed): installed
        case .notInstalled, .working: nil
        }
    }

    var title: String {
        switch self {
        case .notInstalled: "Not installed"
        case .working(let step): step.title
        case .ready: "Ready"
        case .updateAvailable(_, _, let security): security ? "Security update available" : "Update available"
        case .updating(_, _, let step): "Updating · \(step.title)"
        case .failed: "Failed"
        case .disabled: "Disabled"
        }
    }
}

enum IDEACPAdapterEvent: Equatable, Sendable {
    case beginInstall
    case beginUpdate(to: String)
    case advance(IDEACPAdapterStep)
    case activated(version: String)
    case failed(IDEACPAdapterError)
    case cancelled
    case updateFound(available: String, security: Bool)
    case upToDate
    case disable
    case enable
    case removed
}

enum IDEACPAdapterMachine {
    /// The next phase, or nil when the event is not allowed from `phase`. Pure: no I/O.
    static func transition(from phase: IDEACPAdapterPhase, event: IDEACPAdapterEvent) -> IDEACPAdapterPhase? {
        switch (phase, event) {
        case (.notInstalled, .beginInstall):
            return .working(.resolving)
        case (.failed(_, let keeping), .beginInstall) where keeping == nil:
            return .working(.resolving)
        case (.ready(let installed), .beginUpdate(let target)),
             (.updateAvailable(let installed, _, _), .beginUpdate(let target)),
             (.failed(_, let installed?), .beginUpdate(let target)):
            return .updating(from: installed, to: target, step: .resolving)

        case (.working(let current), .advance(let next)) where next > current:
            return .working(next)
        case (.updating(let from, let to, let current), .advance(let next)) where next > current:
            return .updating(from: from, to: to, step: next)

        case (.working(.installing), .activated(let version)),
             (.updating(_, _, .installing), .activated(let version)):
            return .ready(version: version)

        case (.working, .failed(let error)):
            return .failed(error, keeping: nil)
        case (.updating(let from, _, _), .failed(let error)):
            return .failed(error, keeping: from)

        case (.working, .cancelled):
            return .notInstalled
        case (.updating(let from, _, _), .cancelled):
            return .ready(version: from)

        case (.ready(let installed), .updateFound(let available, let security)),
             (.updateAvailable(let installed, _, _), .updateFound(let available, let security)):
            return .updateAvailable(installed: installed, available: available, security: security)
        case (.updateAvailable(let installed, _, _), .upToDate):
            return .ready(version: installed)
        case (.ready, .upToDate):
            return phase

        case (.ready(let version), .disable), (.updateAvailable(let version, _, _), .disable):
            return .disabled(installed: version)
        case (.notInstalled, .disable), (.failed(_, nil), .disable):
            return .disabled(installed: nil)
        case (.failed(_, let keeping?), .disable):
            return .disabled(installed: keeping)
        case (.disabled(let installed?), .enable):
            return .ready(version: installed)
        case (.disabled(nil), .enable):
            return .notInstalled

        case (.ready, .removed), (.updateAvailable, .removed), (.failed, .removed), (.disabled, .removed),
             (.notInstalled, .removed):
            return .notInstalled
        default:
            return nil
        }
    }
}

// MARK: - Manifests on disk

/// `adapters/<id>/active.json`. The version new sessions start, and the one to go back to.
struct IDEACPActiveManifest: Codable, Equatable, Sendable {
    var version: String
    var previous: String?
    var activatedAt: Date
}

/// `adapters/<id>/versions/<version>/install.json`. Written after verification and before
/// activation; a version directory without a valid one is treated as an interrupted install.
struct IDEACPInstallManifest: Codable, Equatable, Sendable, Identifiable {
    var adapterID: String
    var package: String
    var version: String
    var integrity: String
    var signatureKeyID: String
    var provenanceRepository: String
    var publisher: String
    var nodePath: String
    var nodeVersion: String
    /// Path of the entry script relative to the version directory.
    var entryRelativePath: String
    var entrySHA256: String
    var installedBytes: Int64
    var installedAt: Date
    var warnings: [String]

    var id: String { "\(adapterID)@\(version)" }
}

/// A verified, active install ready to launch.
struct IDEACPActiveInstall: Equatable, Sendable {
    var adapterID: String
    var version: String
    var versionDirectory: URL
    var entryURL: URL
    var entrySHA256: String
    var nodePath: String
}

// MARK: - Proposal

/// What the user approves. The installer installs exactly this version and refuses to continue
/// if the registry later reports a different integrity for it.
struct IDEACPInstallProposal: Equatable, Sendable, Identifiable {
    var entryID: String
    var providerName: String
    var packageName: String
    var version: String
    var integrity: String
    var signatureKeyID: String
    var publisher: String
    var repository: String
    var method: String
    var nodeDescription: String
    var nodeVersionRequirement: String?
    var approximateBytes: Int64
    var freeBytes: Int64
    var updatingFrom: String?
    var isSecurityUpdate: Bool
    var warnings: [String]

    var id: String { "\(entryID)@\(version)" }
}
