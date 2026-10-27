import EditorIntelligence
import EditorIntelligenceLSP
import SwiftIntelligence
import XCTest
@testable import Umbra

/// Swift formatting and semantic colours belong to the native providers whether or not SourceKit-LSP
/// is connected. The semantic tier outranks the native one, so any feature SourceKit claims is
/// handed to it as soon as the server starts: its semantic-token provider asks about a document the
/// server never opened (colours freeze) and its formatter ignores the editor's indentation.
@MainActor
final class IDESourceKitRoutingTests: XCTestCase {
    private func makeRegistry() -> (registry: LanguageServiceRegistry, sourceKit: LSPLanguageService) {
        let sourceKit = LSPLanguageService(
            configuration: IDESourceKitServer.definition().configuration, connections: LSPConnectionBox()
        )
        let swift = IDESwiftSupport().languageService
        return (LanguageServiceRegistry(services: [swift, sourceKit]), sourceKit)
    }

    func testSourceKitProvidesNeitherFormattingNorSemanticTokens() {
        let (_, sourceKit) = makeRegistry()
        XCTAssertNil(sourceKit.providers.formatting)
        XCTAssertNil(sourceKit.providers.semanticTokens)
    }

    /// Same defect, same fix: the TypeScript server must not claim semantic tokens either. It keeps
    /// formatting, because the native TypeScript service has no formatter to lose.
    func testTheTypeScriptServerLeavesSemanticTokensToTheNativeService() {
        let server = LSPLanguageService(
            configuration: IDETypeScriptServer.definition().configuration, connections: LSPConnectionBox()
        )
        XCTAssertNil(server.providers.semanticTokens)
        XCTAssertNotNil(server.providers.formatting)
        let registry = LanguageServiceRegistry(services: [IDETypeScriptSupport().languageService, server])
        XCTAssertEqual(registry.capabilities(for: "typescript").features[.semanticTokens]?.service, "typescript")
    }

    func testTheNativeSwiftServiceOwnsFormattingAndSemanticTokens() {
        let (registry, _) = makeRegistry()
        let features = registry.capabilities(for: "swift").features
        XCTAssertEqual(features[.formatting]?.service, "swift")
        XCTAssertEqual(features[.semanticTokens]?.service, "swift")
        XCTAssertTrue(registry.semanticTokens(for: "swift") is SwiftSemanticTokenProvider)
    }
}
