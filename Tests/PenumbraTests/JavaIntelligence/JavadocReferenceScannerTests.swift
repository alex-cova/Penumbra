import XCTest
@testable import JavaIntelligence

final class JavadocReferenceScannerTests: XCTestCase {
    /// `€` marks the click.
    private func reference(_ marked: String) -> JavadocReference.Kind? {
        let comment = marked.replacingOccurrences(of: "€", with: "")
        let marker = marked.range(of: "€")!
        let offset = marked[..<marker.lowerBound].utf8.count
        return JavadocReferenceScanner.reference(in: comment, atByteOffset: offset)?.kind
    }

    func testLinkToATypeAndItsPackageSegments() {
        XCTAssertEqual(reference("/** {@link €Dog} */"), .type(components: ["Dog"]))
        XCTAssertEqual(reference("/** {@link java.€util.List} */"), .type(components: ["java", "util"]))
        XCTAssertEqual(reference("/** {@link java.util.€List} */"), .type(components: ["java", "util", "List"]))
    }

    func testMemberOfAnotherTypeSplitsAtTheHash() {
        XCTAssertEqual(
            reference("/** {@link Dog#€speak()} */"),
            .member(owner: ["Dog"], name: "speak", parameterTypes: [])
        )
        XCTAssertEqual(reference("/** {@link €Dog#speak()} */"), .type(components: ["Dog"]))
    }

    func testMemberOfTheEnclosingTypeHasNoOwner() {
        XCTAssertEqual(reference("/** {@link #€helper} */"), .member(owner: nil, name: "helper", parameterTypes: nil))
    }

    func testParameterTypesAreSimpleNames() {
        XCTAssertEqual(
            reference("/** {@link Dog#€fetch(Ball, java.util.List<String>, int...)} */"),
            .member(owner: ["Dog"], name: "fetch", parameterTypes: ["Ball", "List", "int[]"])
        )
    }

    func testClickOnAParameterTypeInsideTheList() {
        XCTAssertEqual(reference("/** {@link Dog#fetch(€Ball, int)} */"), .type(components: ["Ball"]))
    }

    func testSeeAndThrowsTakeATypeAndParamTakesAName() {
        XCTAssertEqual(reference("/** @see €Strings */"), .type(components: ["Strings"]))
        XCTAssertEqual(reference("/** @throws €DogException when bad */"), .type(components: ["DogException"]))
        XCTAssertEqual(reference("/** @param €name the name */"), .parameter(name: "name"))
    }

    func testTypeParameterBetweenAngleBrackets() {
        XCTAssertEqual(reference("/** @param <€T> the type */"), .typeParameter(name: "T"))
    }

    func testProseAndOtherTagsAreNotReferences() {
        XCTAssertNil(reference("/** Returns the €Dog that barked. */"))
        XCTAssertNil(reference("/** @return the €Dog */"))
        XCTAssertNil(reference("/** {@code €Dog} */"))
    }

    func testTrailingSentenceDotIsNotPartOfTheName() {
        XCTAssertEqual(reference("/** See {@link €Dog}. */"), .type(components: ["Dog"]))
        XCTAssertEqual(reference("/** @see €Dog. */"), .type(components: ["Dog"]))
    }

    func testAccessorFieldNamesPutTheConventionalFieldFirst() {
        XCTAssertEqual(JavaNavigationSession.accessorFieldNames(for: "getName")?.first, "name")
        XCTAssertEqual(JavaNavigationSession.accessorFieldNames(for: "setAge")?.first, "age")
        // A boolean `isActive` field generates `isActive()` too, so the whole name is a candidate.
        XCTAssertEqual(JavaNavigationSession.accessorFieldNames(for: "isActive")?.prefix(2).map { $0 }, ["active", "isActive"])
        // An acronym field keeps its case: `URL` generates `getURL`.
        XCTAssertEqual(JavaNavigationSession.accessorFieldNames(for: "getURL")?.contains("URL"), true)
        XCTAssertNil(JavaNavigationSession.accessorFieldNames(for: "get"))
        XCTAssertNil(JavaNavigationSession.accessorFieldNames(for: "getaway"))
        XCTAssertNil(JavaNavigationSession.accessorFieldNames(for: "speak"))
    }
}
