import XCTest
@testable import Penumbra
import PenumbraLanguages
@testable import Umbra

/// Pins every language mapping that existed before `LanguageDefinition` (docs/LANGUAGE_SUPPORT_PLAN.md,
/// phase 0): file extensions, extensionless file names, Markdown fence tags, grammar identifiers,
/// language configurations and the Set Syntax list. The tables below are written out by hand from the
/// old switches on purpose, so moving the data into definitions cannot silently drop or rename an entry.
final class LanguageMappingCompatibilityTests: XCTestCase {
    func testEveryFileExtension() {
        let table: [String: String] = [
            "txt": "plain", "": "plain",
            "md": "markdown", "markdown": "markdown", "mdown": "markdown",
            "json": "json", "jsonc": "json",
            "csv": "csv", "tsv": "tsv", "tab": "tsv",
            "xml": "xml", "plist": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml",
            "yaml": "yaml", "yml": "yaml",
            "toml": "toml",
            "swift": "swift",
            "java": "java",
            "kt": "kotlin", "kts": "kotlin",
            "gradle": "groovy",
            "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
            "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
            "html": "html", "htm": "html",
            "css": "css",
            "scss": "scss", "sass": "scss",
            "py": "python", "pyw": "python",
            "rs": "rust",
            "go": "go",
            "c": "c", "m": "c", "h": "c",
            "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "mm": "cpp",
            "sh": "shell", "bash": "shell", "zsh": "shell", "command": "shell",
            "sql": "sql",
            "graphql": "graphql", "gql": "graphql",
            "http": "http", "rest": "http",
            "mmd": "mermaid", "mermaid": "mermaid",
            "diff": "diff", "patch": "diff"
        ]
        for (ext, expected) in table {
            XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: ext), expected, "extension '\(ext)'")
            XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: ext.uppercased()), expected, "extension '\(ext)' uppercased")
        }
        for unknown in ["xyzzy", "rb", "php", "cs", "lock", "swiftmodule"] {
            XCTAssertNil(LanguageIdentifier.identifier(forFileExtension: unknown), unknown)
        }
    }

    func testEveryExtensionlessShellFileName() {
        for name in [".bashrc", ".bash_profile", ".bash_aliases", ".bash_logout",
                     ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".profile"] {
            XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/h/\(name)")), "shell", name)
            XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/h/\(name.uppercased())")), "shell", name)
        }
        XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/p/.gitignore")), "plain")
        XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/p/Makefile")), "plain")
    }

    func testEveryFenceTag() {
        let table: [String: String] = [
            "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
            "ts": "typescript", "tsx": "typescript",
            "py": "python",
            "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "terminal": "bash",
            "yml": "yaml", "md": "markdown", "gql": "graphql",
            "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
            "cs": "csharp", "rs": "rust", "kt": "kotlin", "kts": "kotlin", "golang": "go",
            "htm": "html", "jsonc": "json",
            "text": "plain", "plaintext": "plain", "txt": "plain"
        ]
        for (tag, expected) in table {
            XCTAssertEqual(FenceLanguageName.normalize(tag), expected, "tag '\(tag)'")
            XCTAssertEqual(FenceLanguageName.normalize(tag.uppercased()), expected, "tag '\(tag)' uppercased")
        }
        // Tags that are already canonical, and unknown ones, pass through lowercased.
        for tag in ["swift", "java", "rust", "python", "bash", "json", "sql", "go", "c", "cpp", "diff"] {
            XCTAssertEqual(FenceLanguageName.normalize(tag), tag, tag)
        }
        XCTAssertEqual(FenceLanguageName.normalize("Brainfuck"), "brainfuck")
        XCTAssertEqual(FenceLanguageName.normalize("python {highlight=1}"), "python")
        XCTAssertEqual(FenceLanguageName.normalize("py title=a"), "python")
        XCTAssertNil(FenceLanguageName.normalize(nil))
        XCTAssertNil(FenceLanguageName.normalize("   "))
    }

    func testGrammarIdentifiers() {
        BundledLanguages.resetCacheForTesting()
        let withGrammar = [
            "javascript", "typescript", "json", "python", "yaml", "toml", "sql", "html", "xml", "css", "scss",
            "swift", "java", "groovy", "kotlin", "go", "shell", "bash", "sh", "zsh", "graphql", "markdown",
            "markdown_inline", "http", "mermaid", "rust", "c", "cpp", "diff", "patch"
        ]
        for identifier in withGrammar {
            XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: identifier), identifier)
            XCTAssertNotNil(BundledLanguages.language(forIdentifier: identifier), identifier)
        }
        // Known identifiers that deliberately have no grammar, and ones nobody defined.
        for identifier in ["plain", "csv", "tsv", "jsx", "tsx", "csharp", "ruby", "", "JSON", "Java"] {
            XCTAssertNil(TreeSitterLanguage.bundled(forIdentifier: identifier), identifier)
            XCTAssertNil(BundledLanguages.language(forIdentifier: identifier), identifier)
        }
        XCTAssertNil(BundledLanguages.language(forIdentifier: nil))
    }

    func testLanguageConfigurationIdentifiers() {
        let registry = LanguageConfigurationRegistry.builtIns
        for identifier in ["javascript", "jsx", "typescript", "tsx", "java", "swift"] {
            XCTAssertTrue(registry.hasConfiguration(for: identifier), identifier)
        }
        for identifier in ["kotlin", "python", "rust", "go", "c", "cpp", "plain", "groovy", "html"] {
            XCTAssertFalse(registry.hasConfiguration(for: identifier), identifier)
        }
        XCTAssertEqual(registry.configuration(for: "jsx"), .javaScript)
        XCTAssertEqual(registry.configuration(for: "javascript"), .javaScript)
        XCTAssertEqual(registry.configuration(for: "tsx"), .typeScript)
        XCTAssertEqual(registry.configuration(for: "typescript"), .typeScript)
        XCTAssertEqual(registry.configuration(for: "java"), .java)
        XCTAssertEqual(registry.configuration(for: "swift"), .swift)
        XCTAssertEqual(registry.configuration(for: "cobol"), .generic)
    }

    func testSetSyntaxList() {
        let options = IDELanguageSupport.selectableSyntaxes.map { "\($0.id ?? "nil")=\($0.displayName)" }
        XCTAssertEqual(options, [
            "nil=Plain Text", "c=C", "cpp=C++", "css=CSS", "diff=Diff", "go=Go", "graphql=GraphQL", "html=HTML",
            "http=HTTP", "java=Java", "javascript=JavaScript", "json=JSON", "kotlin=Kotlin", "markdown=Markdown",
            "mermaid=Mermaid", "python=Python", "rust=Rust", "scss=SCSS", "shell=Shell Script", "sql=SQL",
            "swift=Swift", "toml=TOML", "typescript=TypeScript", "xml=XML", "yaml=YAML"
        ])
    }

    func testDisplayNames() {
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: nil), "Plain Text")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "java"), "Java")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "shell"), "Shell Script")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "csv"), "CSV")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "tsv"), "TSV")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "groovy"), "Groovy")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "brainfuck"), "Brainfuck")
    }
}
