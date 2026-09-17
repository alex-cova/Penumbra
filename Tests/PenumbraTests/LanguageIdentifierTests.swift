import XCTest
@testable import Penumbra

final class LanguageIdentifierTests: XCTestCase {
    func testCommonExtensionsResolveToTheirIdentifier() {
        let cases: [(String, String)] = [
            ("txt", "plain"),
            ("md", "markdown"), ("markdown", "markdown"), ("mdown", "markdown"),
            ("json", "json"), ("jsonc", "json"),
            ("xml", "xml"), ("plist", "xml"), ("xsd", "xml"), ("xsl", "xml"), ("xslt", "xml"),
            ("yaml", "yaml"), ("yml", "yaml"),
            ("toml", "toml"),
            ("swift", "swift"),
            ("java", "java"),
            ("kt", "kotlin"), ("kts", "kotlin"),
            ("gradle", "groovy"),
            ("js", "javascript"), ("jsx", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"),
            ("ts", "typescript"), ("tsx", "typescript"), ("mts", "typescript"), ("cts", "typescript"),
            ("html", "html"), ("htm", "html"),
            ("css", "css"),
            ("scss", "scss"), ("sass", "scss"),
            ("py", "python"), ("pyw", "python"),
            ("rs", "rust"),
            ("go", "go"),
            ("c", "c"), ("m", "c"), ("h", "c"),
            ("cpp", "cpp"), ("cc", "cpp"), ("cxx", "cpp"), ("hpp", "cpp"), ("hh", "cpp"), ("hxx", "cpp"), ("mm", "cpp"),
            ("sh", "shell"), ("bash", "shell"), ("zsh", "shell"), ("command", "shell"),
            ("sql", "sql"),
            ("graphql", "graphql"), ("gql", "graphql"),
            ("http", "http"), ("rest", "http"),
            ("mmd", "mermaid"), ("mermaid", "mermaid")
        ]
        for (ext, expected) in cases {
            XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: ext), expected, "extension: \(ext)")
        }
    }

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: "SWIFT"), "swift")
        XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: "Js"), "javascript")
    }

    func testEmptyExtensionResolvesToPlain() {
        XCTAssertEqual(LanguageIdentifier.identifier(forFileExtension: ""), "plain")
    }

    func testUnrecognizedExtensionReturnsNil() {
        XCTAssertNil(LanguageIdentifier.identifier(forFileExtension: "xyzzy"))
    }

    func testExtensionlessDotfilesResolveToShell() {
        let names = [".bashrc", ".bash_profile", ".bash_aliases", ".bash_logout",
                     ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".profile"]
        for name in names {
            let url = URL(fileURLWithPath: "/Users/alex/\(name)")
            XCTAssertEqual(LanguageIdentifier.identifier(for: url), "shell", "dotfile: \(name)")
        }
    }

    func testDotfileMatchingIsCaseInsensitive() {
        let url = URL(fileURLWithPath: "/Users/alex/.ZSHRC")
        XCTAssertEqual(LanguageIdentifier.identifier(for: url), "shell")
    }

    func testRegularFileURLFallsBackToExtensionDetection() {
        let url = URL(fileURLWithPath: "/project/main.swift")
        XCTAssertEqual(LanguageIdentifier.identifier(for: url), "swift")
    }

    func testUnknownDotfileFallsBackToExtensionDetection() {
        // ".gitignore" isn't in the shell special-case set and has no extension after the dot
        // (pathExtension is empty), so it should resolve like any other extensionless file.
        let url = URL(fileURLWithPath: "/project/.gitignore")
        XCTAssertEqual(LanguageIdentifier.identifier(for: url), "plain")
    }
}
