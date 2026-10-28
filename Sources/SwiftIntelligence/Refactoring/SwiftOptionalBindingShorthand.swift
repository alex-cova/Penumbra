import Foundation
import SwiftSyntax

/// The `swift-tools-version` a package declares, which also tells how new a compiler its sources may assume.
public struct SwiftToolsVersion: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: SwiftToolsVersion, rhs: SwiftToolsVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// `// swift-tools-version: 5.9` (or `:5.9`, `;5.9`) on the manifest's first line.
    public static func parse(manifest text: String) -> SwiftToolsVersion? {
        guard let first = text.split(whereSeparator: \.isNewline).first,
              let range = first.range(of: "swift-tools-version", options: .caseInsensitive) else { return nil }
        let rest = first[range.upperBound...].drop { $0 == ":" || $0 == ";" || $0 == " " }
        let numbers = rest.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard let major = numbers.first else { return nil }
        return SwiftToolsVersion(major: major, minor: numbers.dropFirst().first ?? 0)
    }

    /// The version of the nearest `Package.swift` above `file`, nil outside a package.
    public static func nearest(to file: URL?) -> SwiftToolsVersion? {
        guard var directory = file?.deletingLastPathComponent().standardizedFileURL else { return nil }
        for _ in 0 ..< 12 {
            let manifest = directory.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8) { return parse(manifest: text) }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// Whether the package may use `if let x` (SE-0345, Swift 5.7). Unknown (a script, an Xcode project) allows it.
    public static func allowsOptionalBindingShorthand(forFileAt file: URL?) -> Bool {
        guard let version = nearest(to: file) else { return true }
        return version >= SwiftToolsVersion(major: 5, minor: 7)
    }
}

/// `if let x = x` ↔ `if let x` (also `var`, `guard` and `while`). Writing the name out is how code that must build
/// with a compiler older than Swift 5.7 does it, and the short form is what the language now offers.
public enum SwiftOptionalBindingShorthand {
    public enum Direction: Sendable, Equatable {
        case shorten
        case expand
    }

    /// What can be done with the optional binding at `caret`: shorten it only when `allowsShorthand`.
    public static func available(in text: String, caret: Int, allowsShorthand: Bool = true) -> Direction? {
        guard let file = SwiftRefactoringFile.load(text), let binding = binding(at: caret, file: file) else { return nil }
        switch classify(binding) {
        case .shortenable: return allowsShorthand ? .shorten : nil
        case .expandable: return .expand
        case nil: return nil
        }
    }

    public static func edits(in text: String, caret: Int, allowsShorthand: Bool = true) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard let binding = binding(at: caret, file: file), let kind = classify(binding) else {
            return .failure(.init("Place the caret on an `if let x = x` or `if let x` condition."))
        }
        switch kind {
        case .shortenable:
            guard allowsShorthand else {
                return .failure(.init("This package's swift-tools-version is older than 5.7, which does not have the short form."))
            }
            guard let initializer = binding.initializer else { return .failure(.init("Nothing to shorten.")) }
            let start = SwiftRefactoringFile.trimmed(binding.pattern).upperBound
            return .success([SwiftTextEdit(bytes: start ..< SwiftRefactoringFile.trimmed(initializer).upperBound, replacement: "")])
        case .expandable:
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return .failure(.init("Only a single name can be written out."))
            }
            let end = SwiftRefactoringFile.trimmed(binding.pattern).upperBound
            return .success([SwiftTextEdit(bytes: end ..< end, replacement: " = \(name)")])
        }
    }

    private enum Kind {
        case shortenable
        case expandable
    }

    private static func classify(_ binding: OptionalBindingConditionSyntax) -> Kind? {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self), binding.typeAnnotation == nil else { return nil }
        guard let initializer = binding.initializer else { return .expandable }
        guard let reference = initializer.value.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil,
              reference.baseName.text == pattern.identifier.text else { return nil }
        return .shortenable
    }

    private static func binding(at caret: Int, file: SwiftRefactoringFile) -> OptionalBindingConditionSyntax? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(max(caret, 0), max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let binding = current.as(OptionalBindingConditionSyntax.self) {
                let range = SwiftRefactoringFile.trimmed(binding)
                return range.contains(caret) || range.upperBound == caret ? binding : nil
            }
            if current.is(CodeBlockSyntax.self) || current.is(CodeBlockItemSyntax.self) { return nil }
            node = current.parent
        }
        return nil
    }
}
