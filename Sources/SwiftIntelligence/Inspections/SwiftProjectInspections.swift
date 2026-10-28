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
        in tree: SourceFileSyntax, url: URL?, isTest: Bool, treatsPublicApiAsUsed: Bool, lookup: any SwiftProjectNameLookup
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
            findings.append(SwiftInspection(
                id: SwiftInspectionRule.unusedDeclaration.code,
                message: "'\(name)' is never used in the project.",
                severity: SwiftInspectionRule.unusedDeclaration.defaultSeverity,
                bytes: start ..< start + candidate.token.text.utf8.count
            ))
        }
        return findings
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
        }

        let treatsPublicApiAsUsed: Bool
        var candidates: [Candidate] = []

        init(treatsPublicApiAsUsed: Bool) {
            self.treatsPublicApiAsUsed = treatsPublicApiAsUsed
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }
        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }
        override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { note(node, node.name, node.modifiers, node.attributes) }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            note(node, node.name, node.modifiers, node.attributes)
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                _ = note(node, pattern.identifier, node.modifiers, node.attributes)
            }
            return .visitChildren
        }

        @discardableResult
        private func note(
            _ node: some SyntaxProtocol, _ name: TokenSyntax, _ modifiers: DeclModifierListSyntax, _ attributes: AttributeListSyntax
        ) -> SyntaxVisitorContinueKind {
            let reachable = SwiftUnusedCode.hasNoAccessModifier(modifiers)
                || (!treatsPublicApiAsUsed && SwiftUnusedCode.isPublicOrOpen(modifiers))
            if attributes.isEmpty, reachable, SwiftUnusedCode.isUnoverriding(modifiers),
               SwiftUnusedCode.declaredAtTypeOrFileLevel(node), !SwiftUnusedCode.isMemberOfConformingType(node) {
                candidates.append(Candidate(name: Identifier(name)?.name ?? name.text, token: name))
            }
            return .visitChildren
        }
    }
}
