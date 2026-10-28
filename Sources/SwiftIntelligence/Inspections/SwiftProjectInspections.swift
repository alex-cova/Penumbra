import Foundation
import SwiftSyntax

/// What the project-wide rules ask of the rest of the project: which files write a name. `SwiftIndex` answers from the
/// names it has indexed, with open buffers over the disk.
public protocol SwiftProjectNameLookup: Sendable {
    /// The files that mention `name` as an identifier. The file being inspected is allowed to be among them.
    func filesMentioning(_ name: String) async -> Set<URL>
}

extension SwiftIndex: SwiftProjectNameLookup {
    public func filesMentioning(_ name: String) async -> Set<URL> {
        candidateFiles(mentioning: name)
    }
}

extension SwiftIndex: SwiftModuleSurfaceLookup {
    public func module(ofFile url: URL) async -> String? {
        module(of: url)
    }
}

/// `unused-declaration`: an internal type, function or property whose name is written nowhere else in the project.
///
/// It goes by names, not by resolved uses, so it can miss an unused declaration whose name something else shares
/// (never report one wrongly because of a name collision). What it leaves alone is what the rest of the code,
/// the runtime or a macro can reach without writing the name: public API (unless asked), anything with an attribute,
/// overrides, members of attributed types, every member of a type or extension that conforms to a protocol (a delegate
/// callback, an associated-type alias or a synthesized `Codable` key is used without being written), padding fields,
/// names of one or two characters (the index does not tell them apart), tests, and `main.swift`.
enum SwiftProjectInspections {
    static func unusedDeclarations(
        in tree: SourceFileSyntax, text: String, url: URL?, isTest: Bool, treatsPublicApiAsUsed: Bool,
        lookup: any SwiftProjectNameLookup
    ) async -> [SwiftInspection] {
        guard !isTest, url?.lastPathComponent != "main.swift" else { return [] }
        let counts = SwiftInspectionWalker.countIdentifiers(in: tree)
        let collector = CandidateCollector(treatsPublicApiAsUsed: treatsPublicApiAsUsed)
        collector.walk(tree)
        let here = url?.standardizedFileURL
        var findings: [SwiftInspection] = []
        var asked: [String: Bool] = [:]
        for candidate in collector.candidates {
            let name = candidate.name
            // Written more than once in this file: used here (or shares its name with something that is).
            guard counts[name] == 1, name.count > 2, !SwiftInspectionWalker.implicitlyUsedNames.contains(name),
                  !isPaddingName(name) else { continue }
            let usedElsewhere: Bool
            if let known = asked[name] {
                usedElsewhere = known
            } else {
                let files = await lookup.filesMentioning(name)
                usedElsewhere = files.contains { $0.standardizedFileURL != here }
                asked[name] = usedElsewhere
            }
            guard !usedElsewhere else { continue }
            let start = candidate.token.positionAfterSkippingLeadingTrivia.utf8Offset
            // The fix deletes the declaration's whole line; a declaration that shares its line with
            // other code, or a variable beside a sibling binding, keeps the report but no fix.
            // Project-wide by construction, so it never runs from Fix all.
            let fixes: [SwiftInspectionFix]
            if let node = candidate.node,
               let line = SwiftInspectionFix.lineDeleting(
                   node.positionAfterSkippingLeadingTrivia.utf8Offset ..< node.endPositionBeforeTrailingTrivia.utf8Offset,
                   in: text
               ) {
                fixes = [SwiftInspectionFix(
                    title: "Safe delete '\(name)'", edits: [.init(bytes: line, replacement: "")], isBatchable: false
                )]
            } else {
                fixes = []
            }
            findings.append(SwiftInspection(
                id: SwiftInspectionRule.unusedDeclaration.code,
                message: "'\(name)' is never used in the project.",
                severity: SwiftInspectionRule.unusedDeclaration.defaultSeverity,
                bytes: start ..< start + candidate.token.text.utf8.count,
                fixes: fixes
            ))
        }
        return findings
    }

    /// `unused-import`: an import whose module the index knows and nothing in the file mentions.
    ///
    /// Conservative by construction, so a hit is safe to delete: the module must have a surface, must
    /// not be the file's own, the import must be plain (no `@testable`, `@_exported`, `import struct`
    /// scoping), the surface must show no re-exports, operators or retroactive conformances, and none
    /// of the surface's names may appear in the file — in code, comments or strings, which all err
    /// toward "used". The import's own line does not count (it names the module).
    static func unusedImports(
        in tree: SourceFileSyntax, text: String, url: URL?, lookup: any SwiftModuleSurfaceLookup
    ) async -> [SwiftInspection] {
        var imports: [(module: String, node: ImportDeclSyntax)] = []
        for statement in tree.statements {
            guard let node = statement.item.as(ImportDeclSyntax.self),
                  let module = node.path.first?.name.text, !module.isEmpty,
                  node.importKindSpecifier == nil, !hasAttribute(node, named: "testable"),
                  !hasAttribute(node, named: "_exported") else { continue }
            imports.append((module, node))
        }
        guard !imports.isEmpty else { return [] }
        let ownModule: String?
        if let url { ownModule = await lookup.module(ofFile: url) } else { ownModule = nil }
        let words = wordsOf(text: text, excludingImports: imports.map(\.node))
        var known: [String: SwiftModuleSurface] = [:]
        var unknown: Set<String> = []
        var findings: [SwiftInspection] = []
        for (module, node) in imports {
            if let own = ownModule, module == own { continue }
            let surface: SwiftModuleSurface?
            if let cached = known[module] {
                surface = cached
            } else if unknown.contains(module) {
                surface = nil
            } else if let built = await lookup.moduleSurface(module) {
                known[module] = built
                surface = built
            } else {
                unknown.insert(module)
                surface = nil
            }
            guard let surface, !surface.hasReexports, !surface.declaresOperators,
                  !surface.hasRetroactiveConformances,
                  !surface.names.contains(where: { words.contains($0) }) else { continue }
            let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = node.endPositionBeforeTrailingTrivia.utf8Offset
            guard let line = SwiftInspectionFix.lineDeleting(start ..< end, in: text) else { continue }
            findings.append(SwiftInspection(
                id: SwiftInspectionRule.unusedImport.code,
                message: "import \(module) is never used in this file.",
                severity: SwiftInspectionRule.unusedImport.defaultSeverity,
                bytes: start ..< end,
                fixes: [SwiftInspectionFix(title: "Remove import", edits: [.init(bytes: line, replacement: "")])]
            ))
        }
        return findings
    }

    private static func hasAttribute(_ node: ImportDeclSyntax, named name: String) -> Bool {
        node.attributes.contains {
            guard case let .attribute(attribute) = $0,
                  let type = attribute.attributeName.as(IdentifierTypeSyntax.self) else { return false }
            return type.name.text == name
        }
    }

    /// Every identifier-like word in the file — code, comments and strings — except inside the import
    /// declarations themselves (an import names its own module). Scalar by scalar, so multibyte
    /// identifiers stay whole.
    private static func wordsOf(text: String, excludingImports imports: [ImportDeclSyntax]) -> Set<String> {
        let excluded = imports.map {
            $0.positionAfterSkippingLeadingTrivia.utf8Offset ..< $0.endPosition.utf8Offset
        }
        var words: Set<String> = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.insert(current) }
            current = ""
        }
        var offset = 0
        for scalar in text.unicodeScalars {
            let inside = excluded.contains { offset >= $0.lowerBound && offset < $0.upperBound }
            if !inside, scalar.value == 95 || Character(scalar).isLetter || Character(scalar).isNumber {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
            offset += scalar.utf8.count
        }
        flush()
        return words
    }

    /// `pad`, `pad4`, `_padding0`: a field that only keeps a GPU or C layout aligned.
    private static func isPaddingName(_ name: String) -> Bool {
        let trimmed = name.drop { $0 == "_" }
        return trimmed.hasPrefix("pad") && trimmed.dropFirst(3).allSatisfy { $0.isNumber || "ding".contains($0) }
    }

    private final class CandidateCollector: SyntaxVisitor {
        struct Candidate {
            let name: String
            let token: TokenSyntax
            /// The declaration to delete, or nil for a variable beside a sibling binding.
            let node: Syntax?
        }

        let treatsPublicApiAsUsed: Bool
        var candidates: [Candidate] = []

        init(treatsPublicApiAsUsed: Bool) {
            self.treatsPublicApiAsUsed = treatsPublicApiAsUsed
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }
        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }
        override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes, deleting: Syntax(node))
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            // Only a declaration that binds one name can go as a whole; the others each keep their
            // report but no fix.
            let whole = node.bindings.count == 1 ? Syntax(node) : nil
            for binding in node.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                _ = note(node, pattern.identifier, node.modifiers, node.attributes, deleting: whole)
            }
            return .visitChildren
        }

        @discardableResult
        private func note(
            _ node: some SyntaxProtocol, _ name: TokenSyntax, _ modifiers: DeclModifierListSyntax, _ attributes: AttributeListSyntax,
            deleting deletable: Syntax?
        ) -> SyntaxVisitorContinueKind {
            let reachable = SwiftUnusedCode.hasNoAccessModifier(modifiers)
                || (!treatsPublicApiAsUsed && SwiftUnusedCode.isPublicOrOpen(modifiers))
            if attributes.isEmpty, reachable, SwiftUnusedCode.isUnoverriding(modifiers),
               SwiftUnusedCode.declaredAtTypeOrFileLevel(node), !SwiftUnusedCode.isMemberOfConformingType(node) {
                candidates.append(Candidate(name: Identifier(name)?.name ?? name.text, token: name, node: deletable))
            }
            return .visitChildren
        }
    }
}
