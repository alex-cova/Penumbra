import XCTest
@testable import Penumbra

/// Tests ``LanguageConfiguration`` and ``LanguageConfigurationRegistry`` as data. The Java and
/// Swift tables can only be checked structurally here — no tree-sitter-java / tree-sitter-swift
/// grammar is vendored, so there is no real tree to scan them against.
final class LanguageConfigurationTests: XCTestCase {
    func testBuiltInRegistryResolvesKnownIdentifiers() {
        let registry = LanguageConfigurationRegistry.builtIns
        XCTAssertTrue(registry.hasConfiguration(for: "javascript"))
        XCTAssertTrue(registry.hasConfiguration(for: "typescript"))
        XCTAssertTrue(registry.hasConfiguration(for: "java"))
        XCTAssertTrue(registry.hasConfiguration(for: "swift"))
    }

    func testUnknownIdentifierFallsBackToGeneric() {
        let registry = LanguageConfigurationRegistry.builtIns
        XCTAssertFalse(registry.hasConfiguration(for: "cobol"))
        XCTAssertEqual(registry.configuration(for: "cobol"), .generic)
        XCTAssertEqual(registry.configuration(for: nil), .generic)
    }

    func testRegisterOverridesEntry() {
        var registry = LanguageConfigurationRegistry.builtIns
        var custom = LanguageConfiguration.generic
        custom.showsBreadcrumbs = false
        registry.register(custom, for: "swift")
        XCTAssertEqual(registry.configuration(for: "swift").showsBreadcrumbs, false)
    }

    func testJavaScriptRuleClassification() {
        let config = LanguageConfiguration.javaScript
        XCTAssertEqual(config.rule(forNodeType: "function_declaration")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "method_definition")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "class_declaration")?.kind, .type)
        XCTAssertNil(config.rule(forNodeType: "identifier"))
        XCTAssertTrue(config.rule(forNodeType: "function_declaration")?.isMethodSeparatorAnchor ?? false)
    }

    func testTypeScriptAddsInterfacesAndTypeAliases() {
        let config = LanguageConfiguration.typeScript
        XCTAssertEqual(config.rule(forNodeType: "interface_declaration")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "type_alias_declaration")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "enum_declaration")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "method_signature")?.kind, .function)
    }

    func testJavaRuleTable() {
        let config = LanguageConfiguration.java
        XCTAssertEqual(config.rule(forNodeType: "method_declaration")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "constructor_declaration")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "record_declaration")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "annotation_type_declaration")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "package_declaration")?.kind, .namespace)
        // The package rule contributes containment but not a breadcrumb crumb.
        XCTAssertEqual(config.rule(forNodeType: "package_declaration")?.isBreadcrumbSegment, false)
    }

    func testSwiftRuleTableAndNameNodeTypes() {
        let config = LanguageConfiguration.swift
        XCTAssertEqual(config.rule(forNodeType: "function_declaration")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "init_declaration")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "protocol_declaration")?.kind, .type)
        let typeRule = config.rule(forNodeType: "class_declaration")
        XCTAssertEqual(typeRule?.kind, .type)
        XCTAssertTrue(typeRule?.nameNodeTypes.contains("type_identifier") ?? false)
    }

    func testGenericUsesSubstringMatching() {
        let config = LanguageConfiguration.generic
        // Substring hints match grammar-specific node names it never enumerates explicitly.
        XCTAssertEqual(config.rule(forNodeType: "function_definition")?.kind, .function)
        XCTAssertEqual(config.rule(forNodeType: "class_specifier")?.kind, .type)
        XCTAssertEqual(config.rule(forNodeType: "namespace_definition")?.kind, .namespace)
        XCTAssertEqual(config.rule(forNodeType: "class")?.kind, .type)
        XCTAssertNil(config.rule(forNodeType: "identifier"))
    }

    func testGenericDoesNotMatchContainerNodes() {
        let config = LanguageConfiguration.generic
        // Containers that merely contain a hint word must not be treated as declarations.
        XCTAssertNil(config.rule(forNodeType: "class_body"))
        XCTAssertNil(config.rule(forNodeType: "function_body"))
        XCTAssertNil(config.rule(forNodeType: "declaration_list"))
        XCTAssertNil(config.rule(forNodeType: "class_heritage"))
    }

    func testMinimumOccurrenceLengthDefault() {
        XCTAssertEqual(LanguageConfiguration.javaScript.minimumOccurrenceLength, 2)
        XCTAssertTrue(LanguageConfiguration.javaScript.highlightsOccurrences)
    }
}
