import Foundation
import GitIntelligence
import Penumbra

/// What the blame column shows for a file: the annotation of every line, from `git blame`, and
/// which commit each annotation stands for (hover, click and the context menu need the commit).
struct IDEBlameAnnotations {
    /// One entry per line; nil is never produced for a blamed line, but the column API allows it.
    var rows: [GutterAnnotation?]
    /// The first blamed line of each annotation id: the commit's details, its previous revision and
    /// the path the line had in it.
    var linesByID: [Int: GitBlameLine]

    static let empty = IDEBlameAnnotations(rows: [], linesByID: [:])
}

enum IDEBlamePresentation {
    /// One entry per line, with consecutive lines of one commit sharing an id so the column
    /// shows their text once. Lines that are not committed (unsaved or unstaged-new text) get
    /// ``edited``, the same annotation the editor gives a line typed after the blame was taken.
    static func annotations(
        for lines: [GitBlameLine],
        settings: IDEBlameSettings = IDEBlameSettings(),
        isDark: Bool = false,
        now: Date = Date(),
        locale: Locale = .current
    ) -> [GutterAnnotation?] {
        build(for: lines, settings: settings, isDark: isDark, now: now, locale: locale).rows
    }

    static func build(
        for lines: [GitBlameLine],
        settings: IDEBlameSettings = IDEBlameSettings(),
        isDark: Bool = false,
        now: Date = Date(),
        locale: Locale = .current
    ) -> IDEBlameAnnotations {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale

        // What the file's commits look like next to each other: the age scale and the newest one.
        var firstLineByHash: [String: GitBlameLine] = [:]
        for line in lines where !line.isUncommitted && firstLineByHash[line.hash] == nil {
            firstLineByHash[line.hash] = line
        }
        let ages = firstLineByHash.mapValues { logAge(of: displayDate(for: $0, settings: settings), now: now) }
        let minAge = ages.values.min() ?? 0
        let maxAge = ages.values.max() ?? 0
        // With one commit there is nothing to tell apart: no bold mark.
        let newestHash = firstLineByHash.count > 1 ? ages.min { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key : nil

        var idByHash: [String: Int] = [:]
        var built: [String: GutterAnnotation] = [:]
        var linesByID: [Int: GitBlameLine] = [:]
        let rows: [GutterAnnotation?] = lines.map { line in
            if line.isUncommitted { return edited }
            if let existing = built[line.hash] { return existing }
            let id = idByHash[line.hash] ?? idByHash.count
            idByHash[line.hash] = id
            let date = displayDate(for: line, settings: settings)
            let annotation = GutterAnnotation(
                id: id,
                text: text(for: line, date: date, settings: settings, formatter: formatter, now: now),
                tooltip: "\(line.shortHash) \(line.summary)\n\(line.author), \(date.formatted(date: .abbreviated, time: .shortened))",
                tint: tint(for: line, age: ages[line.hash] ?? 0, minAge: minAge, maxAge: maxAge, settings: settings, isDark: isDark),
                isEmphasized: line.hash == newestHash
            )
            built[line.hash] = annotation
            linesByID[id] = line
            return annotation
        }
        return IDEBlameAnnotations(rows: rows, linesByID: linesByID)
    }

    /// Shown for lines that are not in any commit. Its id cannot collide with a commit's.
    static let edited = GutterAnnotation(id: -1, text: "Not Committed Yet", tooltip: "This line is not committed yet.")

    // MARK: - Text

    static func displayDate(for line: GitBlameLine, settings: IDEBlameSettings) -> Date {
        settings.usesCommitterTime ? line.committerDate : line.date
    }

    /// The compact date, `yy/MM/dd` in the current time zone, whatever the locale.
    static func compactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        return formatter.string(from: date)
    }

    static func text(
        for line: GitBlameLine, date: Date, settings: IDEBlameSettings, formatter: RelativeDateTimeFormatter, now: Date
    ) -> String {
        let author = settings.showsAuthor ? authorName(line, style: settings.authorStyle) : nil
        var dateText: String?
        if settings.showsDate {
            switch settings.dateStyle {
            case .compact: dateText = compactDate(date)
            case .relative: dateText = formatter.localizedString(for: date, relativeTo: now)
            case .absolute: dateText = date.formatted(.dateTime.locale(formatter.locale).year().month(.abbreviated).day())
            }
        }
        // A compact date reads as a column and leads (`26/09/01 Author`); the wordy ones follow the author.
        var text = settings.dateStyle == .compact
            ? [dateText, author].compactMap { $0 }.joined(separator: " ")
            : [author, dateText].compactMap { $0 }.joined(separator: ", ")
        if settings.showsHash { text = text.isEmpty ? line.shortHash : "\(line.shortHash) \(text)" }
        // Every column off would leave the column blank and unclickable.
        return text.isEmpty ? authorName(line, style: settings.authorStyle) : text
    }

    static func authorName(_ line: GitBlameLine, style: IDEBlameSettings.AuthorStyle) -> String {
        let words = line.author.split(separator: " ").map(String.init)
        switch style {
        case .full: return line.author
        case .first: return words.first ?? line.author
        case .last: return words.last ?? line.author
        case .initials:
            let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
            return letters.isEmpty ? line.author : letters
        case .email: return line.authorEmail.isEmpty ? line.author : line.authorEmail
        }
    }

    // MARK: - Colour

    /// Age on a log scale, so a commit from yesterday and one from last week are told apart as
    /// clearly as one from last year and one from the year before.
    static func logAge(of date: Date, now: Date) -> Double {
        log1p(max(now.timeIntervalSince(date), 0) / 86_400)
    }

    private static func tint(
        for line: GitBlameLine, age: Double, minAge: Double, maxAge: Double,
        settings: IDEBlameSettings, isDark: Bool
    ) -> GutterAnnotationTint? {
        switch settings.coloring {
        case .none:
            return nil
        case .age:
            // The newest commit of the file is the strongest; one commit sits in the middle.
            let recency = maxAge > minAge ? 1 - (age - minAge) / (maxAge - minAge) : 0.5
            let base = isDark ? (0.40, 0.65, 1.0) : (0.20, 0.45, 0.90)
            let alpha = (isDark ? 0.06 : 0.05) + recency * (isDark ? 0.24 : 0.21)
            return GutterAnnotationTint(red: base.0, green: base.1, blue: base.2, alpha: alpha)
        case .author:
            let key = line.authorEmail.isEmpty ? line.author : line.authorEmail
            let color = authorPalette[Int(stableHash(key) % UInt64(authorPalette.count))]
            return GutterAnnotationTint(red: color.0, green: color.1, blue: color.2, alpha: isDark ? 0.22 : 0.17)
        }
    }

    static let authorPalette: [(Double, Double, Double)] = [
        (0.25, 0.52, 0.96), (0.20, 0.70, 0.40), (0.96, 0.60, 0.15), (0.62, 0.40, 0.90),
        (0.92, 0.35, 0.60), (0.10, 0.65, 0.70), (0.85, 0.70, 0.10), (0.90, 0.32, 0.30)
    ]

    /// FNV-1a: the same author gets the same colour in every launch (`hashValue` is seeded per process).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
