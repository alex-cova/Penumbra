import Foundation
import GitIntelligence

/// How the blame column reads and what `git blame` is asked to look through: IntelliJ's Annotate
/// ▸ View and Options. Kept on this Mac (`UserDefaults`), applied to every file.
struct IDEBlameSettings: Equatable, Codable, Sendable {
    enum AuthorStyle: String, Codable, CaseIterable, Sendable {
        case full, first, last, initials, email

        var title: String {
            switch self {
            case .full: "Full Name"
            case .first: "First Name"
            case .last: "Last Name"
            case .initials: "Initials"
            case .email: "Email"
            }
        }
    }

    enum DateStyle: String, Codable, CaseIterable, Sendable {
        /// `26/09/01`: year, month, day in two digits each, before the author.
        case compact
        case relative
        case absolute

        var title: String {
            switch self {
            case .compact: "Compact (26/09/01)"
            case .relative: "Relative (3 days ago)"
            case .absolute: "Absolute (Nov 26, 2026)"
            }
        }
    }

    /// What tints a commit's rows.
    enum Coloring: String, Codable, CaseIterable, Sendable {
        case age, author, none

        var title: String {
            switch self {
            case .age: "By Age"
            case .author: "By Author"
            case .none: "None"
            }
        }
    }

    var showsAuthor = true
    var showsDate = true
    var showsHash = false
    var authorStyle: AuthorStyle = .full
    var dateStyle: DateStyle = .compact
    /// IntelliJ's "Show Commit Timestamp": the committer's time instead of the author's.
    var usesCommitterTime = false
    var coloring: Coloring = .age
    /// `git blame -w`.
    var ignoresWhitespace = false
    /// `git blame -M`.
    var detectsMovesWithinFile = false
    /// `git blame -C`.
    var detectsMovesAcrossFiles = false

    /// The options for one run; `hiddenRevisions` are the file's Hide Revision list.
    func options(hiding hiddenRevisions: [String] = []) -> GitBlameOptions {
        GitBlameOptions(
            ignoreWhitespace: ignoresWhitespace,
            detectMovesWithinFile: detectsMovesWithinFile,
            detectMovesAcrossFiles: detectsMovesAcrossFiles,
            ignoredRevisions: hiddenRevisions
        )
    }

    /// The part of the settings that changes what git answers (so a change re-runs blame, where a
    /// change to the rest only re-presents the lines already read).
    var gitFlags: [Bool] { [ignoresWhitespace, detectsMovesWithinFile, detectsMovesAcrossFiles] }

    static let defaultsKey = "umbra.git.blame.settings"

    static func load(from defaults: UserDefaults = .standard) -> IDEBlameSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(IDEBlameSettings.self, from: data) else { return IDEBlameSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // Every field decodes with a default, so an older or hand-edited value cannot break blame.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsAuthor = try container.decodeIfPresent(Bool.self, forKey: .showsAuthor) ?? true
        showsDate = try container.decodeIfPresent(Bool.self, forKey: .showsDate) ?? true
        showsHash = try container.decodeIfPresent(Bool.self, forKey: .showsHash) ?? false
        authorStyle = try container.decodeIfPresent(AuthorStyle.self, forKey: .authorStyle) ?? .full
        dateStyle = try container.decodeIfPresent(DateStyle.self, forKey: .dateStyle) ?? .compact
        usesCommitterTime = try container.decodeIfPresent(Bool.self, forKey: .usesCommitterTime) ?? false
        coloring = try container.decodeIfPresent(Coloring.self, forKey: .coloring) ?? .age
        ignoresWhitespace = try container.decodeIfPresent(Bool.self, forKey: .ignoresWhitespace) ?? false
        detectsMovesWithinFile = try container.decodeIfPresent(Bool.self, forKey: .detectsMovesWithinFile) ?? false
        detectsMovesAcrossFiles = try container.decodeIfPresent(Bool.self, forKey: .detectsMovesAcrossFiles) ?? false
    }
}
