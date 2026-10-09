import EditorIntelligence
import Foundation
import JavaIntelligence

/// Run, Debug and Modify Run Configuration in the ⌥↩ menu, on a `main` method, a test method or a
/// test class declaration. The actions carry a ``CodeActionCommand``; `IDEWorkspace` does the rest
/// (see `performRunCodeAction`), since only it knows the project and the configurations.
struct IDERunCodeActionProvider: CodeActionProviding {
    static let runCommand = "umbra.run"
    static let debugCommand = "umbra.debug"
    static let modifyCommand = "umbra.modifyRun"

    enum Kind: String { case main, testMethod, testClass }

    struct Target: Equatable {
        let kind: Kind
        /// `Foo.main()`, `testAdds()`, `FooTest`: what the menu items name.
        let title: String
        /// 1-based line of the declaration.
        let line: Int
    }

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard let url = document.url, url.pathExtension.lowercased() == "java",
              let target = Self.target(atLine: position.line + 1, in: document.text, url: url) else { return [] }
        let arguments = [target.kind.rawValue, String(target.line)]
        func action(_ title: String, _ id: String) -> CodeAction {
            CodeAction(title: title, kind: "run", edits: [], command: CodeActionCommand(id: id, arguments: arguments))
        }
        return [
            action("Run ‘\(target.title)’", Self.runCommand),
            action("Debug ‘\(target.title)’", Self.debugCommand),
            action("Modify Run Configuration…", Self.modifyCommand)
        ]
    }

    /// What `line` (1-based) declares that can be run: a `main`, a test method, or a test class.
    /// Parses the file, so it is for an explicit request, not a keystroke.
    static func target(atLine line: Int, in source: String, url: URL) -> Target? {
        if let main = JavaMainMethod.locations(in: source, fileName: url.lastPathComponent).first(where: { $0.line == line }) {
            return Target(kind: .main, title: "\(main.simpleClassName).main()", line: line)
        }
        let tests = JavaTestDiscovery.discover(source: source, url: url)
        for (_, methods) in tests {
            if let method = methods.first(where: { $0.line == line }) {
                return Target(kind: .testMethod, title: "\(method.methodName)()", line: line)
            }
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return nil }
        let text = String(lines[line - 1])
        for qualified in tests.keys {
            let simple = qualified.split(separator: ".").last.map(String.init) ?? qualified
            if text.range(of: #"\b(class|record|enum|interface)\s+"# + NSRegularExpression.escapedPattern(for: simple) + #"\b"#, options: .regularExpression) != nil {
                return Target(kind: .testClass, title: simple, line: line)
            }
        }
        return nil
    }
}

/// Several providers asked in turn, their actions in one list: the language's own fixes first.
struct IDECompositeCodeActionProvider: CodeActionProviding {
    let providers: [any CodeActionProviding]

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        var result: [CodeAction] = []
        for provider in providers {
            result += await provider.codeActions(for: document, at: position, diagnostics: diagnostics)
        }
        return result
    }
}
