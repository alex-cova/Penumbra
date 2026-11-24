import Foundation

/// A GitHub.com repository identity derived from a Git fetch URL.
struct GitHubRemote: Hashable, Sendable {
    let owner: String
    let repository: String

    init?(fetchURL: String) {
        guard !fetchURL.isEmpty, !fetchURL.utf8.contains(where: { $0 <= 32 || $0 >= 127 }) else { return nil }
        let path: Substring
        if let colon = fetchURL.firstIndex(of: ":"), fetchURL[..<colon].lowercased() == "git@github.com" {
            path = fetchURL[fetchURL.index(after: colon)...]
        } else {
            guard let components = URLComponents(string: fetchURL),
                  let host = components.percentEncodedHost?.lowercased(),
                  components.password == nil, components.query == nil, components.fragment == nil,
                  components.percentEncodedPath.hasPrefix("/")
            else { return nil }
            switch (components.scheme?.lowercased(), host, components.port, components.percentEncodedUser) {
            case ("https", "github.com", nil, nil), ("https", "github.com", 443, nil),
                 ("ssh", "github.com", nil, "git"), ("ssh", "github.com", 22, "git"),
                 ("ssh", "ssh.github.com", 443, "git"):
                break
            default:
                return nil
            }
            path = components.percentEncodedPath.dropFirst()
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2 else { return nil }
        let owner = segments[0]
        let repository = segments[1].hasSuffix(".git") ? segments[1].dropLast(4) : segments[1]
        guard (1...39).contains(owner.utf8.count),
              owner.utf8.allSatisfy({ Self.alphanumeric($0) || $0 == 45 }),
              owner.first != "-", owner.last != "-",
              (1...100).contains(repository.utf8.count), repository != ".", repository != "..",
              repository.utf8.allSatisfy({ Self.alphanumeric($0) || [45, 46, 95].contains($0) })
        else { return nil }
        self.owner = owner.lowercased()
        self.repository = repository.lowercased()
    }

    private static func alphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

struct GitHubRepositoryMetadata: Decodable, Equatable, Sendable {
    let id: Int64
    let fullName: String
    let defaultBranch: String
    let visibility: String
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, archived, visibility
        case fullName = "full_name"
        case defaultBranch = "default_branch"
    }
}
