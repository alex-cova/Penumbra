import Foundation

/// A repository's page on a hosting service, worked out from a remote URL: where a file, a commit
/// or a branch lives in the browser. Pure.
struct IDEGitHostingURL: Equatable, Sendable {
    enum Service: Sendable {
        case github
        case gitlab
        case bitbucket
        /// Gitea, Forgejo and Codeberg.
        case gitea
    }

    let host: String
    /// `owner/repo`, or `group/subgroup/repo` on GitLab.
    let path: String
    let service: Service

    var base: URL? { URL(string: "https://\(host)/\(path)") }

    var serviceName: String {
        switch service {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .gitea: host.contains("codeberg") ? "Codeberg" : "Gitea"
        }
    }

    /// Parses `git@host:owner/repo.git`, `ssh://git@host[:port]/owner/repo.git`, `https://[user@]host/…`
    /// and `git://host/…`. Nil for a local path or something unrecognisable.
    init?(remoteURL: String) {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if let range = text.range(of: "://") {
            var rest = String(text[range.upperBound...])
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) {
                rest = String(rest[rest.index(after: at)...])
            }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            // A port belongs to the transport, not to the web address.
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
            host = String(text[text.index(after: at)..<colon])
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, host.contains("."), path.contains("/") else { return nil }
        self.host = host.lowercased()
        self.path = path
        self.service = Self.service(forHost: self.host)
    }

    private static func service(forHost host: String) -> Service {
        if host.contains("gitlab") { return .gitlab }
        if host.contains("bitbucket") { return .bitbucket }
        if host.contains("gitea") || host.contains("codeberg") || host.contains("forgejo") { return .gitea }
        return .github
    }

    // MARK: - Pages

    func commitURL(_ hash: String) -> URL? {
        switch service {
        case .github, .gitea: url("commit/\(hash)")
        case .gitlab: url("-/commit/\(hash)")
        case .bitbucket: url("commits/\(hash)")
        }
    }

    func branchURL(_ name: String) -> URL? {
        switch service {
        case .github: url("tree/\(Self.encode(name))")
        case .gitlab: url("-/tree/\(Self.encode(name))")
        case .bitbucket: url("branch/\(Self.encode(name))")
        case .gitea: url("src/branch/\(Self.encode(name))")
        }
    }

    /// A file at a branch name or commit, with optional 1-based lines highlighted.
    func fileURL(ref: String, path: String, isCommit: Bool, lines: ClosedRange<Int>? = nil) -> URL? {
        let encodedRef = Self.encode(ref)
        let encodedPath = Self.encode(path)
        var location: String
        var fragment = ""
        switch service {
        case .github:
            location = "blob/\(encodedRef)/\(encodedPath)"
            if let lines { fragment = lines.count == 1 ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)-L\(lines.upperBound)" }
        case .gitlab:
            location = "-/blob/\(encodedRef)/\(encodedPath)"
            if let lines { fragment = lines.count == 1 ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)-\(lines.upperBound)" }
        case .bitbucket:
            location = "src/\(encodedRef)/\(encodedPath)"
            if let lines { fragment = lines.count == 1 ? "lines-\(lines.lowerBound)" : "lines-\(lines.lowerBound):\(lines.upperBound)" }
        case .gitea:
            location = "src/\(isCommit ? "commit" : "branch")/\(encodedRef)/\(encodedPath)"
            if let lines { fragment = lines.count == 1 ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)-L\(lines.upperBound)" }
        }
        return url(location + (fragment.isEmpty ? "" : "#" + fragment))
    }

    private func url(_ tail: String) -> URL? {
        URL(string: "https://\(host)/\(path)/\(tail)")
    }

    /// Percent-encodes each path component and keeps the slashes: branch names and file paths have them.
    private static func encode(_ text: String) -> String {
        text.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? String($0) }
            .joined(separator: "/")
    }
}
