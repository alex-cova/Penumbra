import EditorIntelligence
import XCTest
@testable import Umbra

/// Pins the features the native Swift and TypeScript services answer today. A semantic tier that
/// lands later shows up here as a second owner; this test is the syntactic baseline.
@MainActor
final class LanguageCapabilityMatrixTests: XCTestCase {
    func testSwiftSyntacticTierMatchesTheNativeProviders() {
        let report = LanguageServiceRegistry(services: [IDESwiftSupport().languageService]).capabilities(for: "swift")
        XCTAssertEqual(report.features[.completion], LanguageFeatureOwner(service: "swift", fidelity: .syntactic))
        XCTAssertEqual(report.features[.hover]?.fidelity, .syntactic)
        XCTAssertEqual(report.features[.signatureHelp]?.service, "swift")
        XCTAssertEqual(report.features[.rename]?.service, "swift")
        XCTAssertEqual(report.features[.diagnostics]?.service, "swift")
        XCTAssertEqual(report.features[.semanticTokens]?.service, "swift")
        XCTAssertEqual(report.features[.structure]?.service, "swift")
        XCTAssertEqual(report.features[.breadcrumbs]?.service, "swift")
        XCTAssertEqual(report.features[.lineMarkers]?.service, "swift")
        XCTAssertEqual(report.features[.typeHierarchy]?.service, "swift")
        XCTAssertEqual(report.features[.callHierarchy]?.service, "swift")
        XCTAssertEqual(report.features[.codeGeneration]?.service, "swift")
        XCTAssertEqual(report.features[.codeActions], LanguageFeatureOwner(service: "swift", fidelity: .syntactic))
        XCTAssertEqual(report.features[.formatting]?.service, "swift")
        XCTAssertEqual(report.features[.refactoring]?.service, "swift")
        XCTAssertNil(report.features[.inlayHints])
    }

    func testTypeScriptSyntacticTierHasNoSignatureHelpOrHierarchies() {
        let report = LanguageServiceRegistry(services: [IDETypeScriptSupport().languageService]).capabilities(for: "typescript")
        XCTAssertEqual(report.features[.completion]?.service, "typescript")
        XCTAssertEqual(report.features[.hover]?.service, "typescript")
        XCTAssertEqual(report.features[.rename]?.service, "typescript")
        XCTAssertEqual(report.features[.diagnostics]?.service, "typescript")
        XCTAssertEqual(report.features[.semanticTokens]?.service, "typescript")
        XCTAssertEqual(report.features[.structure]?.service, "typescript")
        XCTAssertEqual(report.features[.breadcrumbs]?.service, "typescript")
        XCTAssertNil(report.features[.signatureHelp])
        XCTAssertNil(report.features[.lineMarkers])
        XCTAssertNil(report.features[.typeHierarchy])
        XCTAssertNil(report.features[.callHierarchy])
        XCTAssertNil(report.features[.codeGeneration])
        XCTAssertNil(report.features[.formatting])
    }

    func testAForeignLanguageGetsNothingFromEitherService() {
        let registry = LanguageServiceRegistry(services: [
            IDESwiftSupport().languageService,
            IDETypeScriptSupport().languageService
        ])
        XCTAssertTrue(registry.capabilities(for: "java").features.isEmpty)
        XCTAssertTrue(registry.services(for: "java").isEmpty)
    }
}
