import EditorIntelligence
import Foundation

/// "Generate…" for Swift types: a memberwise initializer, a `description`, and `CodingKeys`.
public struct SwiftCodeGenerationProvider: CodeGenerationProviding {
    private let index: SwiftIndex

    public init(index: SwiftIndex) {
        self.index = index
    }

    public static let codingKeys = CodeGenerationKind("codingKeys")
    public static let equatable = CodeGenerationKind("equatable")
    public static let hashable = CodeGenerationKind("hashable")

    public func generationMenu(_ context: RefactoringContext) async -> CodeGenerationMenu? {
        guard context.document.languageIdentifier == SwiftAnalysis.languageIdentifier,
              let site = await site(for: context) else { return nil }
        var options: [CodeGenerationOption] = []
        if site.type.kind == .class || site.type.kind == .struct || site.type.kind == .actor {
            options.append(CodeGenerationOption(
                kind: .constructor, title: "Initializer", fields: site.initializerFields, allowsEmptySelection: true
            ))
        }
        if !site.storedFields.isEmpty {
            options.append(CodeGenerationOption(kind: .toString, title: "description (CustomStringConvertible)", fields: site.storedFields))
            options.append(CodeGenerationOption(kind: Self.codingKeys, title: "CodingKeys", fields: site.storedFields))
            options.append(CodeGenerationOption(kind: Self.equatable, title: "Equatable", fields: site.storedFields))
            options.append(CodeGenerationOption(kind: Self.hashable, title: "Hashable", fields: site.storedFields))
        }
        return options.isEmpty ? nil : CodeGenerationMenu(typeName: site.type.name, options: options)
    }

    public func generate(
        _ kind: CodeGenerationKind, fieldNames: [String], context: RefactoringContext
    ) async -> WorkspaceEditPlan {
        let title = "Generate"
        guard context.document.languageIdentifier == SwiftAnalysis.languageIdentifier else {
            return WorkspaceEditPlan(blockingError: "Generate is only available in Swift files.", title: title)
        }
        guard let url = context.documentURL ?? context.document.url else {
            return WorkspaceEditPlan(blockingError: "Save the file before generating code.", title: title)
        }
        guard let site = await site(for: context) else {
            return WorkspaceEditPlan(blockingError: "Place the caret inside a class, struct or enum.", title: title)
        }
        let wanted = Set(fieldNames)
        let layout = Layout(site: site)
        var block: [String]
        var extraEdits: [(byte: Int, text: String, description: String)] = []

        switch kind {
        case .constructor:
            let fields = site.initializerFields.filter { wanted.contains($0.name) }
            let labels = fields.map { $0.name }
            if site.type.members.contains(where: { $0.kind == .initializer && $0.parameters.map { $0.label ?? "_" } == labels }) {
                return WorkspaceEditPlan(blockingError: "init(\(labels.map { $0 + ":" }.joined())) already exists.", title: title)
            }
            let parameters = fields.map { "\($0.name): \($0.typeText)" }.joined(separator: ", ")
            block = ["init(\(parameters)) {"] + fields.map { "\(layout.unit)self.\($0.name) = \($0.name)" } + ["}"]
        case .toString:
            if site.type.members.contains(where: { $0.name == "description" && $0.kind == .property }) {
                return WorkspaceEditPlan(blockingError: "description already exists.", title: title)
            }
            let fields = site.storedFields.filter { wanted.contains($0.name) }
            guard !fields.isEmpty else { return WorkspaceEditPlan(blockingError: "Select at least one property.", title: title) }
            let parts = fields.map { "\($0.name): \\(\($0.name))" }.joined(separator: ", ")
            block = ["var description: String {", "\(layout.unit)\"\(site.type.name)(\(parts))\"", "}"]
            if !site.type.inherits.contains("CustomStringConvertible"), !site.type.signature.contains(" where "),
               site.type.bodyBytes.lowerBound > 0 {
                // Right before the opening brace, after any generic parameters and inheritance.
                let brace = site.type.bodyBytes.lowerBound - 1
                let hasInheritance = !site.type.inherits.isEmpty
                extraEdits.append((
                    byte: layout.endOfHeader(before: brace, in: site.text),
                    text: (hasInheritance ? ", " : ": ") + "CustomStringConvertible",
                    description: "add CustomStringConvertible"
                ))
            }
        case Self.codingKeys:
            if site.type.members.contains(where: { $0.name == "CodingKeys" }) {
                return WorkspaceEditPlan(blockingError: "CodingKeys already exists.", title: title)
            }
            let fields = site.storedFields.filter { wanted.contains($0.name) }
            guard !fields.isEmpty else { return WorkspaceEditPlan(blockingError: "Select at least one property.", title: title) }
            block = ["enum CodingKeys: String, CodingKey {", "\(layout.unit)case \(fields.map(\.name).joined(separator: ", "))", "}"]
        case Self.equatable:
            if site.type.members.contains(where: { $0.name == "==" && $0.kind == .function }) {
                return WorkspaceEditPlan(blockingError: "== already exists.", title: title)
            }
            block = equalityBlock(site: site, wanted: wanted, layout: layout)
            guard !block.isEmpty else {
                return WorkspaceEditPlan(blockingError: "Select at least one property.", title: title)
            }
            extraEdits.append(contentsOf: conformanceEdit(name: "Equatable", site: site, layout: layout))
        case Self.hashable:
            if site.type.members.contains(where: { $0.name == "hash" && $0.kind == .function }) {
                return WorkspaceEditPlan(blockingError: "hash(into:) already exists.", title: title)
            }
            block = hashBlock(site: site, wanted: wanted, layout: layout)
            guard !block.isEmpty else {
                return WorkspaceEditPlan(blockingError: "Select at least one property.", title: title)
            }
            extraEdits.append(contentsOf: conformanceEdit(name: "Hashable", site: site, layout: layout))
        default:
            return WorkspaceEditPlan(blockingError: "That can't be generated.", title: title)
        }

        let insertion = layout.insertionPoint(kind: kind, site: site)
        let text = layout.render(block, leadingBlankLine: insertion.needsBlankLine, site: site)
        var entries = [entry(url: url, byte: insertion.byte, text: text, site: site, description: "generate")]
        for extra in extraEdits {
            entries.append(entry(url: url, byte: extra.byte, text: extra.text, site: site, description: extra.description))
        }
        return WorkspaceEditPlan(entries: entries, title: title)
    }

    private func equalityBlock(site: Site, wanted: Set<String>, layout: Layout) -> [String] {
        let fields = site.storedFields.filter { wanted.contains($0.name) }
        guard !fields.isEmpty else { return [] }
        let checks = fields.map { "lhs.\($0.name) == rhs.\($0.name)" }.joined(separator: " && ")
        return [
            "static func == (lhs: \(site.type.name), rhs: \(site.type.name)) -> Bool {",
            "\(layout.unit)\(checks)",
            "}"
        ]
    }

    private func hashBlock(site: Site, wanted: Set<String>, layout: Layout) -> [String] {
        let fields = site.storedFields.filter { wanted.contains($0.name) }
        guard !fields.isEmpty else { return [] }
        return ["func hash(into hasher: inout Hasher) {"]
            + fields.map { "\(layout.unit)hasher.combine(\($0.name))" }
            + ["}"]
    }

    /// The inheritance edit that `description` uses, for another protocol name.
    private func conformanceEdit(name: String, site: Site, layout: Layout) -> [(byte: Int, text: String, description: String)] {
        guard !site.type.inherits.contains(name), !site.type.signature.contains(" where "),
              site.type.bodyBytes.lowerBound > 0 else { return [] }
        let brace = site.type.bodyBytes.lowerBound - 1
        let hasInheritance = !site.type.inherits.isEmpty
        return [(
            byte: layout.endOfHeader(before: brace, in: site.text),
            text: (hasInheritance ? ", " : ": ") + name,
            description: "add \(name)"
        )]
    }

    // MARK: Site

    private struct Field: Hashable {
        var name: String
        var typeText: String
    }

    private struct Site {
        var type: SwiftFileModel.Declaration
        var text: SourceTextMap
        var storedFields: [CodeGenerationField]
        var initializerFields: [CodeGenerationField]
    }

    private func site(for context: RefactoringContext) async -> Site? {
        guard let parsed = await SwiftAnalysis.parse(document: context.document) else { return nil }
        if let url = context.document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let type = parsed.model.enclosingTypes(at: byte).last(where: { $0.kind != .extension && $0.kind != .protocol })
        else { return nil }
        let resolver = SwiftResolver(index: index, model: parsed.model, url: context.document.url)
        var stored: [CodeGenerationField] = []
        var initializable: [CodeGenerationField] = []
        for member in type.members where member.kind == .property && !member.isStatic && !member.isComputed {
            var typeText = member.typeText
            if typeText == nil, let chain = member.valueChain {
                typeText = await resolver.typeName(of: chain, at: member.fullBytes.lowerBound)
            }
            guard let typeText else { continue }
            let field = CodeGenerationField(name: member.name, typeText: typeText)
            stored.append(field)
            if !(member.isConstant && member.hasInitializer) { initializable.append(field) }
        }
        return Site(type: type, text: parsed.text, storedFields: stored, initializerFields: initializable)
    }

    // MARK: Layout

    private struct Layout {
        /// The indentation of the type's members, and one more level.
        var memberIndent: String
        var unit: String

        init(site: Site) {
            let bytes = site.text.utf8
            func indent(ofLineContaining byte: Int) -> String {
                var start = min(byte, bytes.count)
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                var end = start
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                return String(decoding: bytes[start..<end], as: UTF8.self)
            }
            let typeIndent = indent(ofLineContaining: site.type.fullBytes.lowerBound)
            if let first = site.type.members.first {
                memberIndent = indent(ofLineContaining: first.fullBytes.lowerBound)
            } else {
                memberIndent = typeIndent + (typeIndent.contains("\t") ? "\t" : "    ")
            }
            unit = memberIndent.contains("\t") ? "\t" : "    "
        }

        /// Where the new member goes: an initializer after the stored properties, the rest at the end.
        func insertionPoint(kind: CodeGenerationKind, site: Site) -> (byte: Int, needsBlankLine: Bool) {
            let members = site.type.members
            if kind == .constructor, let last = members.last(where: { $0.kind == .property }) {
                return (last.fullBytes.upperBound, true)
            }
            if members.isEmpty { return (site.type.bodyBytes.lowerBound, false) }
            // Before the closing brace's line.
            let close = site.type.bodyBytes.upperBound
            var lineStart = close
            let bytes = site.text.utf8
            while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
            let blank = String(decoding: bytes[lineStart..<close], as: UTF8.self).allSatisfy { $0 == " " || $0 == "\t" }
            return (blank ? max(lineStart - 1, site.type.bodyBytes.lowerBound) : close, true)
        }

        func render(_ lines: [String], leadingBlankLine: Bool, site: Site) -> String {
            let body = lines.map { $0.isEmpty ? $0 : memberIndent + $0 }.joined(separator: "\n")
            return (leadingBlankLine ? "\n\n" : "\n") + body
        }

        /// The byte just before the type's opening brace, with the blanks before it left alone.
        func endOfHeader(before brace: Int, in text: SourceTextMap) -> Int {
            var position = brace
            while position > 0, text.utf8[position - 1] == 0x20 || text.utf8[position - 1] == 0x09 { position -= 1 }
            return position
        }
    }

    private func entry(url: URL, byte: Int, text: String, site: Site, description: String) -> WorkspaceEditPlanEntry {
        let position = site.text.position(atByte: byte)
        let range = EditorIntelligence.TextRange(start: position, end: position)
        let line = site.text.lineContents(containingUTF16: position.utf16Offset)
        return WorkspaceEditPlanEntry(
            url: url.standardizedFileURL, range: range, oldText: "", newText: text, lineText: line.text,
            description: description
        )
    }
}
