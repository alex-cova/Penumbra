import XCTest
@testable import JavaIntelligence

final class JavaVMOptionsTests: XCTestCase {
    private func option(_ id: String) throws -> JavaVMOption {
        try XCTUnwrap(JavaVMOptions.all.first { $0.id == id }, "no option \(id)")
    }

    func testIdsAreUniqueAndArgumentsAreNotEmpty() {
        let ids = JavaVMOptions.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(JavaVMOptions.all.allSatisfy { !$0.arguments.isEmpty && !$0.summary.isEmpty })
        for category in JavaVMOption.Category.allCases {
            XCTAssertFalse(JavaVMOptions.options(in: category).isEmpty, "\(category) has no options")
        }
    }

    func testAddingToEmptyTextWritesTheOption() throws {
        let vector = try option("vector-api")
        XCTAssertEqual(JavaVMOptions.adding(vector, to: ""), "--add-modules jdk.incubator.vector")
        XCTAssertEqual(JavaVMOptions.adding(vector, to: "  \n"), "--add-modules jdk.incubator.vector")
    }

    func testAddingKeepsWhatWasTypedAsWritten() throws {
        let assertions = try option("assertions")
        let text = JavaVMOptions.adding(assertions, to: "-Dgreeting='hello world'  -Xmx1g ")
        XCTAssertEqual(text, "-Dgreeting='hello world'  -Xmx1g -ea")
    }

    func testEnabledIsReadFromSeparateTokensAndFromTheEqualsForm() throws {
        let vector = try option("vector-api")
        XCTAssertTrue(JavaVMOptions.isEnabled(vector, in: "-Xmx1g --add-modules jdk.incubator.vector"))
        XCTAssertTrue(JavaVMOptions.isEnabled(vector, in: "--add-modules=jdk.incubator.vector"))
        XCTAssertFalse(JavaVMOptions.isEnabled(vector, in: "--add-modules java.sql"))
        XCTAssertFalse(JavaVMOptions.isEnabled(vector, in: "jdk.incubator.vector"))
        XCTAssertFalse(JavaVMOptions.isEnabled(vector, in: ""))
    }

    func testAddingAnEnabledOptionLeavesTheTextAlone() throws {
        let vector = try option("vector-api")
        let text = "--add-modules=jdk.incubator.vector   -ea"
        XCTAssertEqual(JavaVMOptions.adding(vector, to: text), text)
        let gc = try option("gc-g1")
        XCTAssertEqual(JavaVMOptions.adding(gc, to: "-XX:+UseG1GC  -ea"), "-XX:+UseG1GC  -ea")
    }

    func testRemovingTakesOutOnlyItsOwnTokens() throws {
        let vector = try option("vector-api")
        XCTAssertEqual(
            JavaVMOptions.removing(vector, from: "-Xmx1g --add-modules jdk.incubator.vector -ea"),
            "-Xmx1g -ea"
        )
        XCTAssertEqual(JavaVMOptions.removing(vector, from: "--add-modules=jdk.incubator.vector"), "")
        XCTAssertEqual(JavaVMOptions.removing(vector, from: "-ea  -Xmx1g"), "-ea  -Xmx1g")
    }

    func testRemovingKeepsAnotherAddModulesFlag() throws {
        let vector = try option("vector-api")
        XCTAssertEqual(
            JavaVMOptions.removing(vector, from: "--add-modules java.sql --add-modules jdk.incubator.vector"),
            "--add-modules java.sql"
        )
    }

    func testAHeapSizeReplacesAnother() throws {
        let two = try option("heap-2g")
        XCTAssertEqual(JavaVMOptions.adding(two, to: "-Xmx512m -ea"), "-ea -Xmx2g")
        XCTAssertEqual(JavaVMOptions.adding(two, to: "-Xms256m"), "-Xms256m -Xmx2g")
        XCTAssertTrue(JavaVMOptions.isEnabled(two, in: "-Xmx2g"))
        XCTAssertFalse(JavaVMOptions.isEnabled(two, in: "-Xmx512m"))
    }

    func testACollectorReplacesTheOthers() throws {
        let zgc = try option("gc-zgc")
        XCTAssertEqual(JavaVMOptions.adding(zgc, to: "-XX:+UseG1GC -ea"), "-ea -XX:+UseZGC")
        XCTAssertEqual(JavaVMOptions.adding(zgc, to: "-XX:+UseParallelGC -XX:+UseSerialGC"), "-XX:+UseZGC")
    }

    func testAnArgumentWithSpacesSurvivesTheRewrite() throws {
        let heap = try option("heap-1g")
        let text = JavaVMOptions.adding(heap, to: "-Dpath=\"/Users/dev/My Project\" -Xmx512m")
        XCTAssertEqual(JavaCommandLine.split(text), ["-Dpath=/Users/dev/My Project", "-Xmx1g"])
    }

    func testAvailabilityFollowsTheFeatureVersion() throws {
        let vector = try option("vector-api")
        XCTAssertFalse(JavaVMOptions.isAvailable(vector, featureVersion: 11))
        XCTAssertTrue(JavaVMOptions.isAvailable(vector, featureVersion: 16))
        XCTAssertTrue(JavaVMOptions.isAvailable(vector, featureVersion: nil))
        XCTAssertTrue(JavaVMOptions.isAvailable(try option("assertions"), featureVersion: 8))
    }

    func testJoinIsTheInverseOfSplit() {
        let arguments = ["-Xmx1g", "a b", "", "say \"hi\"", "back\\slash", "it's"]
        XCTAssertEqual(JavaCommandLine.split(JavaCommandLine.join(arguments)), arguments)
        XCTAssertEqual(JavaCommandLine.join([]), "")
    }
}
