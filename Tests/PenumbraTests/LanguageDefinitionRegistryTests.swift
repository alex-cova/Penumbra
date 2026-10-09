import XCTest
@testable import Penumbra
import PenumbraLanguages
@testable import Umbra

final class LanguageDefinitionRegistryTests: XCTestCase {
    // MARK: Registry semantics (own instances, so the shared registry is untouched)

    func testRegisteredDefinitionIsFoundByEveryKey() {
        let registry = LanguageDefinitionRegistry()
        registry.register(LanguageDefinition(
            id: "zig", displayName: "Zig", fileExtensions: ["zig", "ZON"], fileNames: ["Build.zig.zon"],
            aliases: ["ziglang"], fenceAliases: ["zg"], fenceName: "zig"
        ))
        XCTAssertEqual(registry.identifier(forFileExtension: "zig"), "zig")
        XCTAssertEqual(registry.identifier(forFileExtension: "Zon"), "zig")
        XCTAssertEqual(registry.identifier(forFileName: "build.zig.zon"), "zig")
        XCTAssertEqual(registry.fenceName(forTag: "zg"), "zig")
        XCTAssertEqual(registry.definition(forIdentifier: "zig")?.displayName, "Zig")
        XCTAssertEqual(registry.definition(forIdentifier: "ziglang")?.id, "zig")
        XCTAssertNil(registry.definition(forIdentifier: "Zig"), "identifiers are case-sensitive")
        XCTAssertNil(registry.identifier(forFileExtension: "rs"))
    }

    func testLaterRegistrationWinsAnExtension() {
        let registry = LanguageDefinitionRegistry(definitions: [
            LanguageDefinition(id: "c", displayName: "C", fileExtensions: ["h"]),
            LanguageDefinition(id: "cpp", displayName: "C++", fileExtensions: ["hpp"])
        ])
        XCTAssertEqual(registry.identifier(forFileExtension: "h"), "c")
        registry.register(LanguageDefinition(id: "objc", displayName: "Objective-C", fileExtensions: ["h", "m"]))
        XCTAssertEqual(registry.identifier(forFileExtension: "h"), "objc")
        XCTAssertEqual(registry.identifier(forFileExtension: "hpp"), "cpp")
    }

    func testReRegisteringAnIdentifierReplacesItAndDropsItsOldKeys() {
        let registry = LanguageDefinitionRegistry(definitions: [
            LanguageDefinition(id: "lang", displayName: "Lang", fileExtensions: ["a", "b"], fenceAliases: ["old"])
        ])
        registry.register(LanguageDefinition(id: "lang", displayName: "Lang 2", fileExtensions: ["c"]))
        XCTAssertNil(registry.identifier(forFileExtension: "a"))
        XCTAssertNil(registry.fenceName(forTag: "old"))
        XCTAssertEqual(registry.identifier(forFileExtension: "c"), "lang")
        XCTAssertEqual(registry.definition(forIdentifier: "lang")?.displayName, "Lang 2")
    }

    func testUnregisterRemovesDefinitionAndGrammar() {
        let registry = LanguageDefinitionRegistry()
        registry.register(LanguageDefinition(id: "lang", displayName: "Lang", fileExtensions: ["lg"], grammar: { .json }))
        XCTAssertNotNil(registry.grammar(forIdentifier: "lang"))
        registry.unregister(identifier: "lang")
        XCTAssertNil(registry.definition(forIdentifier: "lang"))
        XCTAssertNil(registry.identifier(forFileExtension: "lg"))
        XCTAssertNil(registry.grammar(forIdentifier: "lang"))
    }

    func testGrammarResolvesThroughAliasesAndIsNotCreatedUntilAsked() {
        let counter = OSAllocatedCounter()
        let registry = LanguageDefinitionRegistry(definitions: [
            LanguageDefinition(id: "shell", displayName: "Shell", aliases: ["bash"], grammar: {
                counter.increment()
                return .json
            })
        ])
        XCTAssertEqual(counter.value, 0)
        XCTAssertNotNil(registry.grammar(forIdentifier: "bash"))
        XCTAssertNotNil(registry.grammar(forIdentifier: "shell"))
        XCTAssertEqual(counter.value, 2)
        XCTAssertNil(registry.grammar(forIdentifier: "Bash"))
    }

    func testDefaultGrammarDoesNotReplaceAHostGrammar() {
        let registry = LanguageDefinitionRegistry()
        let host = LanguageDefinition(id: "rust", displayName: "Rust", grammar: { .json })
        registry.register(host)
        let bundledCalls = OSAllocatedCounter()
        registry.setGrammar(forIdentifier: "rust", replacingExisting: false) {
            bundledCalls.increment()
            return .json
        }
        _ = registry.grammar(forIdentifier: "rust")
        XCTAssertEqual(bundledCalls.value, 0)
        registry.setGrammar(forIdentifier: "rust") {
            bundledCalls.increment()
            return .json
        }
        _ = registry.grammar(forIdentifier: "rust")
        XCTAssertEqual(bundledCalls.value, 1, "an explicit set replaces the host's")
    }

    func testRegisteringAGrammarlessDefinitionKeepsAnInstalledGrammar() {
        let registry = LanguageDefinitionRegistry()
        registry.setGrammar(forIdentifier: "lang") { .json }
        registry.register(LanguageDefinition(id: "lang", displayName: "Lang", fileExtensions: ["lg"]))
        XCTAssertNotNil(registry.grammar(forIdentifier: "lang"))
    }

    func testSelectableDefinitionsAreSortedByNameIgnoringCase() {
        let registry = LanguageDefinitionRegistry(definitions: [
            LanguageDefinition(id: "scss", displayName: "SCSS", isSelectable: true),
            LanguageDefinition(id: "hidden", displayName: "Aardvark", isSelectable: false),
            LanguageDefinition(id: "sql", displayName: "SQL", isSelectable: true),
            LanguageDefinition(id: "c", displayName: "C", isSelectable: true),
            LanguageDefinition(id: "cpp", displayName: "C++", isSelectable: true),
            LanguageDefinition(id: "go", displayName: "go", isSelectable: true)
        ])
        XCTAssertEqual(registry.selectableDefinitions.map(\.id), ["c", "cpp", "go", "scss", "sql"])
    }

    func testConfigurationsListOnlyDefinitionsThatHaveOne() {
        var custom = LanguageConfiguration.generic
        custom.showsBreadcrumbs = false
        let registry = LanguageDefinitionRegistry(definitions: [
            LanguageDefinition(id: "a", displayName: "A", configuration: custom),
            LanguageDefinition(id: "b", displayName: "B")
        ])
        XCTAssertEqual(Set(registry.configurations.keys), ["a"])
    }

    func testConcurrentRegistrationAndLookup() {
        let registry = LanguageDefinitionRegistry(definitions: LanguageDefinition.builtIns)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index % 10 == 0 {
                registry.register(LanguageDefinition(id: "lang\(index)", displayName: "L\(index)", fileExtensions: ["x\(index)"]))
            } else {
                XCTAssertEqual(registry.identifier(forFileExtension: "swift"), "swift")
                XCTAssertEqual(registry.fenceName(forTag: "py"), "python")
            }
        }
        XCTAssertEqual(registry.identifier(forFileExtension: "x100"), "lang100")
    }

    // MARK: One registration reaches every lookup (the shared registry, restored afterwards)

    func testOneRegisteredDefinitionReachesEveryLookup() throws {
        var configuration = LanguageConfiguration.generic
        configuration.showsBreadcrumbs = false
        let definition = LanguageDefinition(
            id: "umbra-test-lang", displayName: "Umbra Test Lang",
            fileExtensions: ["utl"], fileNames: ["UTLfile"], fenceAliases: ["utl"],
            configuration: configuration, isSelectable: true,
            grammar: { .json }
        )
        LanguageDefinitionRegistry.shared.register(definition)
        addTeardownBlock {
            LanguageDefinitionRegistry.shared.unregister(identifier: "umbra-test-lang")
            BundledLanguages.resetCacheForTesting()
        }

        XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: "utl"), "umbra-test-lang")
        XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/p/main.UTL")), "umbra-test-lang")
        XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/p/utlfile")), "umbra-test-lang")
        XCTAssertEqual(FenceLanguageName.normalize("utl {x=1}"), "umbra-test-lang")
        XCTAssertNotNil(BundledLanguages.language(forIdentifier: "umbra-test-lang"))
        XCTAssertEqual(LanguageConfigurationRegistry.builtIns.configuration(for: "umbra-test-lang").showsBreadcrumbs, false)

        let menu = IDELanguageSupport.selectableSyntaxes
        XCTAssertTrue(menu.contains { $0.id == "umbra-test-lang" && $0.displayName == "Umbra Test Lang" })
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "umbra-test-lang"), "Umbra Test Lang")
        XCTAssertEqual(menu.first?.id, nil, "Plain Text stays first")
    }

    func testSharedRegistryIsBackToBuiltInsAfterwards() {
        XCTAssertNil(LanguageIdentifier.identifier(forFileExtension: "utl"))
        XCTAssertNil(LanguageDefinitionRegistry.shared.definition(forIdentifier: "umbra-test-lang"))
        XCTAssertEqual(IDELanguageSupport.selectableSyntaxes.count, 25)
    }
}

/// A counter a `@Sendable` grammar closure can bump.
private final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
