import Foundation
import SubprocessKit

/// A `major.minor.patch` triple. Enough of semver for `engines.node`.
struct IDEACPSemver: Equatable, Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `v22.1.0`, `22`, `22.1`. Missing parts are zero. Pre-release suffixes are ignored.
    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") { body.removeFirst() }
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = String(body[..<cut]) }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(parts[0]!, parts.count > 1 ? parts[1]! : 0, parts.count > 2 ? parts[2]! : 0)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    enum RangeResult: Equatable, Sendable {
        case satisfied, unsatisfied
        /// The range uses syntax this parser does not read. Shown as a warning, not a failure.
        case unknown
    }

    /// Evaluates `>=22`, `>=18 <24`, `^20.1`, `~20.1`, `20`, and `||` alternatives.
    func satisfies(_ range: String) -> RangeResult {
        var sawUnknown = false
        for alternative in range.components(separatedBy: "||") {
            switch evaluate(alternative) {
            case .satisfied: return .satisfied
            case .unknown: sawUnknown = true
            case .unsatisfied: break
            }
        }
        return sawUnknown ? .unknown : .unsatisfied
    }

    private func evaluate(_ clause: String) -> RangeResult {
        let tokens = clause.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return .satisfied }
        for token in tokens {
            switch matches(token) {
            case .satisfied: continue
            case .unsatisfied: return .unsatisfied
            case .unknown: return .unknown
            }
        }
        return .satisfied
    }

    private func matches(_ token: String) -> RangeResult {
        let operators = [">=", "<=", ">", "<", "=", "^", "~"]
        var op = "="
        var body = token
        for candidate in operators where token.hasPrefix(candidate) {
            op = candidate
            body = String(token.dropFirst(candidate.count))
            break
        }
        if body == "*" || body == "x" || body.isEmpty { return .satisfied }
        guard let target = IDEACPSemver(body) else { return .unknown }
        let hasMinor = body.split(separator: ".").count > 1
        switch op {
        case ">=": return self >= target ? .satisfied : .unsatisfied
        case ">": return self > target ? .satisfied : .unsatisfied
        case "<=": return self <= target ? .satisfied : .unsatisfied
        case "<": return self < target ? .satisfied : .unsatisfied
        case "^":
            guard self >= target else { return .unsatisfied }
            return major == target.major ? .satisfied : .unsatisfied
        case "~":
            guard self >= target else { return .unsatisfied }
            return major == target.major && (!hasMinor || minor == target.minor) ? .satisfied : .unsatisfied
        default:
            if !hasMinor { return major == target.major ? .satisfied : .unsatisfied }
            return self == target ? .satisfied : .unsatisfied
        }
    }
}

/// `node` and `npm` as the user has them. Locating only looks at `PATH`. The one process this
/// starts is `node --version`, the user's own tool, never anything downloaded.
struct IDEACPNodeInstallation: Equatable, Sendable {
    var node: String
    var npm: String
    var version: IDEACPSemver

    var directory: String { (node as NSString).deletingLastPathComponent }
}

enum IDEACPNodeRuntime {
    /// Both `node` and `npm`, from the first `PATH` directory that has `node`; `npm` is looked up
    /// there first and then anywhere on the path.
    static func locate(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (node: String, npm: String)? {
        let directories = pathValue.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in directories where isExecutable("\(directory)/node") {
            if isExecutable("\(directory)/npm") { return ("\(directory)/node", "\(directory)/npm") }
            if let npm = directories.map({ "\($0)/npm" }).first(where: isExecutable) {
                return ("\(directory)/node", npm)
            }
        }
        return nil
    }

    /// Just `node`, which is all that running an installed adapter needs.
    static func locateNode(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        pathValue.split(separator: ":").map { "\($0)/node" }.first(where: isExecutable)
    }

    static func parseVersion(_ output: String) -> IDEACPSemver? {
        IDEACPSemver(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func detect(pathValue: String, environment: [String: String]) async -> IDEACPNodeInstallation? {
        guard let found = locate(pathValue: pathValue) else { return nil }
        var request = SubprocessRequest(executable: found.node, arguments: ["--version"])
        request.environment = environment
        request.timeout = .seconds(8)
        guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded,
              let version = parseVersion(result.stdout.text)
        else { return nil }
        return IDEACPNodeInstallation(node: found.node, npm: found.npm, version: version)
    }

    /// The range an adapter needs: its own `engines.node`, else the catalog's fallback major.
    static func requirement(engines: [String: String]?, fallbackMajor: Int) -> String {
        engines?["node"] ?? ">=\(fallbackMajor)"
    }

    static func check(_ node: IDEACPNodeInstallation?, requirement: String) throws -> [String] {
        guard let node else { throw IDEACPAdapterError.nodeMissing }
        switch node.version.satisfies(requirement) {
        case .satisfied: return []
        case .unsatisfied: throw IDEACPAdapterError.nodeTooOld(found: node.version.description, required: "Node.js \(requirement)")
        case .unknown: return ["Umbra could not read the Node.js requirement “\(requirement)”; the install will tell if it does not fit."]
        }
    }
}
