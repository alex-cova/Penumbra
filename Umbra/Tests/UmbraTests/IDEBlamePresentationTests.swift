import XCTest
import GitIntelligence
@testable import Penumbra
@testable import Umbra

final class IDEBlamePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hashA = String(repeating: "a", count: 40)
    private let hashB = String(repeating: "b", count: 40)

    private func line(_ hash: String, author: String = "Alex", daysAgo: Double = 3, summary: String = "Fix it") -> GitBlameLine {
        GitBlameLine(hash: hash, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), summary: summary,
                     isUncommitted: hash.allSatisfy { $0 == "0" })
    }

    /// The wordy, relative style: the compact default would put a date in front of the author.
    private var relative: IDEBlameSettings {
        var settings = IDEBlameSettings()
        settings.dateStyle = .relative
        return settings
    }

    private func annotations(_ lines: [GitBlameLine]) -> [GutterAnnotation?] {
        IDEBlamePresentation.annotations(for: lines, settings: relative, now: now, locale: Locale(identifier: "en_US"))
    }

    func testLinesOfOneCommitShareAnAnnotation() throws {
        let result = annotations([line(hashA), line(hashA), line(hashB, author: "Sam")])
        XCTAssertEqual(result[0], result[1])
        XCTAssertNotEqual(result[1], result[2])
        XCTAssertEqual(try XCTUnwrap(result[2]).text.hasPrefix("Sam, "), true)
    }

    func testTheTextNamesTheAuthorAndAge() throws {
        let text = try XCTUnwrap(annotations([line(hashA, daysAgo: 3)])[0]).text
        XCTAssertEqual(text, "Alex, 3 days ago")
    }

    func testTheTooltipCarriesTheCommitAndSummary() throws {
        let tooltip = try XCTUnwrap(annotations([line(hashA, summary: "Add blame")])[0]).tooltip
        XCTAssertTrue(tooltip.hasPrefix("aaaaaaa Add blame"), tooltip)
    }

    func testUncommittedLinesUseTheEditedAnnotation() {
        let zeros = String(repeating: "0", count: 40)
        let result = annotations([line(hashA), line(zeros), line(zeros), line(hashA)])
        XCTAssertEqual(result[1], IDEBlamePresentation.edited)
        XCTAssertEqual(result[2], IDEBlamePresentation.edited)
        // A commit keeps its id across the uncommitted stretch, so it is one block on each side.
        XCTAssertEqual(result[0]?.id, result[3]?.id)
        XCTAssertNotEqual(result[0]?.id, IDEBlamePresentation.edited.id)
    }

    func testAnEmptyBlameHasNoRows() {
        XCTAssertTrue(annotations([]).isEmpty)
    }

    // MARK: - Columns, colour and emphasis

    private func detailed(
        _ hash: String, author: String = "Ada Lovelace", email: String = "ada@example.org", daysAgo: Double = 3,
        committer: String = "", committerDaysAgo: Double? = nil
    ) -> GitBlameLine {
        GitBlameLine(
            hash: hash, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), summary: "Fix it",
            isUncommitted: false, authorEmail: email, committer: committer.isEmpty ? author : committer,
            committerDate: now.addingTimeInterval(-(committerDaysAgo ?? daysAgo) * 86_400),
            originalLine: 4, originalPath: "src/A.swift")
    }

    private func build(_ lines: [GitBlameLine], _ settings: IDEBlameSettings? = nil, dark: Bool = false) -> IDEBlameAnnotations {
        IDEBlamePresentation.build(for: lines, settings: settings ?? relative, isDark: dark, now: now, locale: Locale(identifier: "en_US"))
    }

    private func text(_ settings: IDEBlameSettings, _ line: GitBlameLine? = nil) throws -> String {
        try XCTUnwrap(build([line ?? detailed(hashA)], settings).rows[0]).text
    }

    func testTheAuthorCanBeShownInFiveWays() throws {
        var settings = relative
        settings.showsDate = false
        for (style, expected) in [(IDEBlameSettings.AuthorStyle.full, "Ada Lovelace"), (.first, "Ada"), (.last, "Lovelace"),
                                  (.initials, "AL"), (.email, "ada@example.org")] {
            settings.authorStyle = style
            XCTAssertEqual(try text(settings), expected, "\(style)")
        }
        // No email recorded: the name stands in.
        settings.authorStyle = .email
        XCTAssertEqual(try text(settings, detailed(hashA, email: "")), "Ada Lovelace")
    }

    func testTheColumnsFollowTheViewSettings() throws {
        var settings = relative
        settings.showsHash = true
        XCTAssertEqual(try text(settings), "aaaaaaa Ada Lovelace, 3 days ago")
        settings.showsAuthor = false
        XCTAssertEqual(try text(settings), "aaaaaaa 3 days ago")
        settings.dateStyle = .absolute
        XCTAssertTrue(try text(settings).contains("2027"))
        XCTAssertFalse(try text(settings).contains("ago"))
        // Every column off would leave nothing to hover or click: the author stays.
        settings.showsHash = false
        settings.showsDate = false
        XCTAssertEqual(try text(settings), "Ada Lovelace")
    }

    func testTheDefaultIsACompactDateThenTheAuthor() throws {
        // `26/09/01 Author`: year, month, day, then the name; the line numbers come after the column.
        XCTAssertEqual(IDEBlameSettings().dateStyle, .compact)
        let date = now.addingTimeInterval(-3 * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        let expected = formatter.string(from: date)
        XCTAssertEqual(expected.count, 8)
        XCTAssertEqual(try text(IDEBlameSettings()), "\(expected) Ada Lovelace")
        var settings = IDEBlameSettings()
        settings.showsAuthor = false
        XCTAssertEqual(try text(settings), expected)
        settings.showsAuthor = true
        settings.showsHash = true
        XCTAssertEqual(try text(settings), "aaaaaaa \(expected) Ada Lovelace")
        settings.showsDate = false
        XCTAssertEqual(try text(settings), "aaaaaaa Ada Lovelace")
    }

    func testCommitterTimeReplacesTheAuthorTime() throws {
        let line = detailed(hashA, daysAgo: 400, committer: "Bob", committerDaysAgo: 3)
        // The author's time is 400 days back ("1 yr. ago" in the short style), not the committer's three.
        let byAuthor = try text(relative, line)
        XCTAssertFalse(byAuthor.contains("3 days"), byAuthor)
        XCTAssertTrue(byAuthor.contains("yr"), byAuthor)
        var settings = relative
        settings.usesCommitterTime = true
        XCTAssertEqual(try text(settings, line), "Ada Lovelace, 3 days ago")
    }

    func testAgeHeatIsStrongestForTheNewestCommit() throws {
        let hashC = String(repeating: "c", count: 40)
        let rows = build([detailed(hashA, daysAgo: 400), detailed(hashB, daysAgo: 30), detailed(hashC, daysAgo: 1)]).rows
        let alphas = try rows.map { try XCTUnwrap($0?.tint).alpha }
        XCTAssertLessThan(alphas[0], alphas[1])
        XCTAssertLessThan(alphas[1], alphas[2])
        // One commit sits in the middle of the range.
        let single = try XCTUnwrap(build([detailed(hashA)]).rows[0]?.tint).alpha
        XCTAssertGreaterThan(single, alphas[0])
        XCTAssertLessThan(single, alphas[2])
    }

    func testTheNewestRevisionIsBoldOnlyWhenTheFileHasSeveral() throws {
        XCTAssertEqual(build([detailed(hashA)]).rows[0]?.isEmphasized, false)
        let rows = build([detailed(hashA, daysAgo: 30), detailed(hashB, daysAgo: 1), detailed(hashA, daysAgo: 30)]).rows
        XCTAssertEqual(rows.map { $0?.isEmphasized }, [false, true, false])
        XCTAssertEqual(rows[1]?.displayTextForTesting, "Ada Lovelace, 1 day ago*")
    }

    func testAuthorColoursAreStableAndTellAuthorsApart() throws {
        var settings = IDEBlameSettings()
        settings.coloring = .author
        let ada1 = detailed(hashA, author: "Ada", email: "ada@example.org")
        let ada2 = detailed(hashB, author: "Ada", email: "ada@example.org", daysAgo: 20)
        let rows = build([ada1, ada2], settings).rows
        XCTAssertEqual(rows[0]?.tint, rows[1]?.tint, "one author, one colour")
        // The colour comes from a fixed hash, not from `hashValue`, which differs in every launch.
        XCTAssertEqual(IDEBlamePresentation.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        let colours = Set((0..<40).compactMap { i -> GutterAnnotationTint? in
            build([detailed(hashA, author: "Author \(i)", email: "author\(i)@example.org")], settings).rows[0]?.tint
        })
        XCTAssertGreaterThan(colours.count, 4, "authors spread over the palette")
    }

    func testNoColouringHasNoTintAndTheSchemeChangesIt() throws {
        var settings = IDEBlameSettings()
        settings.coloring = .none
        XCTAssertNil(build([detailed(hashA)], settings).rows[0]?.tint)
        XCTAssertNotEqual(build([detailed(hashA)], dark: false).rows[0]?.tint, build([detailed(hashA)], dark: true).rows[0]?.tint)
    }

    func testEachAnnotationIdKnowsItsFirstLine() throws {
        let first = detailed(hashA, daysAgo: 30)
        let second = detailed(hashB, daysAgo: 1)
        let result = build([first, first, second, GitBlameLine(hash: String(repeating: "0", count: 40), author: "x", date: now,
                                                                summary: "", isUncommitted: true)])
        XCTAssertEqual(result.rows[0]?.id, result.rows[1]?.id)
        XCTAssertEqual(result.linesByID[try XCTUnwrap(result.rows[0]?.id)]?.hash, hashA)
        XCTAssertEqual(result.linesByID[try XCTUnwrap(result.rows[2]?.id)]?.hash, hashB)
        XCTAssertEqual(result.rows[3], IDEBlamePresentation.edited)
        XCTAssertNil(result.linesByID[IDEBlamePresentation.edited.id], "the edited row is no commit")
    }
}

extension GutterAnnotation {
    /// What the column draws.
    fileprivate var displayTextForTesting: String { isEmphasized ? text + "*" : text }
}
