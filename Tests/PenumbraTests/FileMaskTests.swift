import XCTest
import EditorIntelligence

final class FileMaskTests: XCTestCase {
    private func matches(_ mask: String, _ path: String) -> Bool {
        FileMask(mask).matches(relativePath: path)
    }

    func testAnEmptyMaskMatchesEverything() {
        XCTAssertTrue(FileMask("").isEmpty)
        XCTAssertTrue(FileMask("  , ").isEmpty)
        XCTAssertTrue(matches("", "a/b/c.txt"))
    }

    func testANamePatternMatchesFileNamesAtAnyDepth() {
        XCTAssertTrue(matches("*.java", "A.java"))
        XCTAssertTrue(matches("*.java", "src/main/A.java"))
        XCTAssertFalse(matches("*.java", "src/main/A.kt"))
        XCTAssertFalse(matches("*.java", "src/A.java.bak"))
        XCTAssertTrue(matches("A?.txt", "x/AB.txt"))
        XCTAssertFalse(matches("A?.txt", "x/ABC.txt"))
    }

    func testAPathPatternIsAnchoredAtTheRoot() {
        XCTAssertTrue(matches("src/*.java", "src/A.java"))
        XCTAssertFalse(matches("src/*.java", "src/main/A.java"), "* does not cross directories")
        XCTAssertFalse(matches("src/*.java", "other/src/A.java"))
        XCTAssertTrue(matches("src/**", "src/main/deep/A.java"))
        XCTAssertFalse(matches("src/**", "test/A.java"))
    }

    func testDoubleStarCrossesDirectoriesIncludingNone() {
        XCTAssertTrue(matches("**/gen/*.java", "gen/A.java"))
        XCTAssertTrue(matches("**/gen/*.java", "a/b/gen/A.java"))
        XCTAssertFalse(matches("**/gen/*.java", "a/b/gen/deeper/A.java"))
        XCTAssertTrue(matches("src/**/A.java", "src/A.java"))
        XCTAssertTrue(matches("src/**/A.java", "src/x/y/A.java"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(matches("*.JAVA", "a/b.java"))
        XCTAssertTrue(matches("SRC/**", "src/a.txt"))
    }

    func testSeveralPatternsMatchAnyOfThem() {
        XCTAssertTrue(matches("*.java, *.kt", "A.kt"))
        XCTAssertTrue(matches("*.java *.kt", "A.java"))
        XCTAssertFalse(matches("*.java, *.kt", "A.swift"))
    }

    func testExclusionsWinWhereverTheyAreWritten() {
        XCTAssertFalse(matches("*.java, !*Test.java", "FooTest.java"))
        XCTAssertFalse(matches("!*Test.java, *.java", "FooTest.java"))
        XCTAssertTrue(matches("*.java, !*Test.java", "Foo.java"))
        XCTAssertTrue(matches("!*Test.java", "Foo.kt"), "Only exclusions: everything else stays in")
    }

    func testAnExclusionAppliesToADirectorysContents() {
        XCTAssertFalse(matches("!build", "build/out/A.java"))
        XCTAssertFalse(matches("!build", "module/build/A.java"), "A bare name matches at any depth")
        XCTAssertFalse(matches("!build/**", "build/A.java"))
        XCTAssertTrue(matches("!build/**", "src/build.java"))
        XCTAssertFalse(matches("!build/", "a/b/build/A.java"), "A trailing slash names a directory anywhere")
        XCTAssertFalse(matches("!src/gen", "src/gen/A.java"))
        XCTAssertTrue(matches("!src/gen", "other/src/gen/A.java"), "A path pattern is anchored")
    }

    func testAnExcludedDirectoryCanBePrunedItself() {
        XCTAssertTrue(FileMask("!build/**").isExcluded(relativePath: "build"))
        XCTAssertTrue(FileMask("!build").isExcluded(relativePath: "a/build"))
        XCTAssertFalse(FileMask("!build/**").isExcluded(relativePath: "src"))
        XCTAssertFalse(FileMask("*.java").isExcluded(relativePath: "src"), "Includes never prune")
    }

    func testInvalidPatternsReportThemselvesAndMatchNothing() {
        for bad in ["!", "a**b", "src//x", "**x"] {
            let mask = FileMask("*.java, \(bad)")
            XCTAssertFalse(mask.isValid, bad)
            XCTAssertEqual(mask.invalidPatterns, [bad])
            XCTAssertFalse(mask.matches(relativePath: "A.java"), "\(bad) must not fall back to matching everything")
        }
        XCTAssertFalse(FileMask("").isValid == false)
    }

    func testRegexCharactersInPatternsAreLiteral() {
        XCTAssertTrue(matches("a+b(1).txt", "a+b(1).txt"))
        XCTAssertFalse(matches("a.txt", "aXtxt"))
        XCTAssertFalse(matches("[ab].txt", "a.txt"))
        XCTAssertTrue(matches("[ab].txt", "[ab].txt"))
    }
}
