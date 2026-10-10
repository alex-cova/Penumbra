import EditorIntelligence
import Foundation
import JavaIntelligence

/// Primary completion for Swift. A member access that cannot be typed returns nothing, so word
/// completion stays out of `x.`. Locals come unfiltered; project declarations are prefiltered.
struct SwiftCompletionProvider: CompletionProvider {
    let name = SwiftAnalysis.providerName
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        context.document.languageIdentifier == SwiftAnalysis.languageIdentifier
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard isPrimary(for: context) else { return [] }
        guard let parsed = SwiftAnalysis.parse(document: context.document) else { return [] }
        if let url = context.document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        if Task.isCancelled { return [] }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        let prefixStart = parsed.text.byteOffset(utf16: context.range.start.utf16Offset)
        let resolver = SwiftResolver(index: index, model: parsed.model, url: context.document.url)
        let site = SwiftSite.classify(byte: byte, prefixStart: prefixStart, parsed: parsed)
        switch site {
        case .none:
            return []
        case .member(let receiver, let at):
            return await memberItems(receiver, at: at, resolver: resolver, context: context)
        case .implicitMember(let at):
            return await implicitItems(at: at, parsed: parsed, resolver: resolver, context: context)
        case .type:
            return await typeItems(parsed: parsed, resolver: resolver, context: context)
        case .importedModule:
            return await moduleItems(context: context)
        case .value:
            return await scopedItems(parsed: parsed, resolver: resolver, context: context, byte: byte)
        }
    }

    // MARK: Member access

    private func memberItems(
        _ receiver: SwiftChain, at byte: Int, resolver: SwiftResolver, context: CompletionContext
    ) async -> [CompletionItem] {
        guard let value = await resolver.value(of: receiver, at: byte) else { return [] }
        let file = context.document.url
        switch value {
        case .instance(let type):
            let type = SwiftTypeNames.unwrappedOptional(type)
            var items: [CompletionItem] = []
            var seen = Set<String>()
            for ref in await index.members(ofType: type, visibleFrom: file) where !ref.declaration.isStatic
                && ref.declaration.kind != .enumCase && ref.declaration.kind != .initializer {
                guard seen.insert(ref.declaration.name + "/" + signatureKey(ref.declaration)).inserted else { continue }
                items.append(memberItem(ref.declaration, owner: ref.owner, receiver: type, context: context))
            }
            for member in SwiftStandardLibrary.members(ofType: type) {
                guard seen.insert(member.name + "/" + member.signature).inserted else { continue }
                items.append(standardItem(member, context: context))
            }
            return items
        case .metatype(let type):
            var items: [CompletionItem] = []
            var seen = Set<String>()
            for ref in await index.members(ofType: type, visibleFrom: file)
            where ref.declaration.isStatic || ref.declaration.kind == .enumCase || ref.declaration.kind == .initializer {
                guard seen.insert(ref.declaration.name + "/" + signatureKey(ref.declaration)).inserted else { continue }
                items.append(memberItem(ref.declaration, owner: ref.owner, receiver: type, context: context))
            }
            for nested in await index.nestedTypes(in: type, visibleFrom: file)
            where seen.insert(nested.declaration.name + "/type").inserted {
                items.append(typeItem(nested.declaration, priority: 25, context: context))
            }
            if seen.insert("init/").inserted {
                items.append(item(label: "init", kind: .constructor, detail: nil, priority: 20, context: context))
            }
            return items
        case .module(let module):
            var items: [CompletionItem] = []
            for export in await index.exports(matching: context.prefix, limit: 200) where export.module == module {
                items.append(exportItem(export, edits: [], context: context))
            }
            return items
        case .callable:
            return []
        }
    }

    private func implicitItems(
        at byte: Int, parsed: SwiftParsed, resolver: SwiftResolver, context: CompletionContext
    ) async -> [CompletionItem] {
        guard let expected = await SwiftExpectedType.find(at: byte, parsed: parsed, resolver: resolver) else { return [] }
        var items: [CompletionItem] = []
        var seen = Set<String>()
        for ref in await index.members(ofType: expected, visibleFrom: context.document.url)
        where ref.declaration.isStatic || ref.declaration.kind == .enumCase {
            // A static member only fits when it produces the type itself.
            if ref.declaration.kind != .enumCase,
               let produced = ref.declaration.typeName.map({ SwiftResolver.replacingSelf($0, with: expected) }),
               produced != expected, ref.declaration.kind == .function || ref.declaration.kind == .property {
                continue
            }
            guard seen.insert(ref.declaration.name + "/" + signatureKey(ref.declaration)).inserted else { continue }
            items.append(memberItem(ref.declaration, owner: ref.owner, receiver: expected, context: context))
        }
        return items
    }

    // MARK: Scope

    private func scopedItems(
        parsed: SwiftParsed, resolver: SwiftResolver, context: CompletionContext, byte: Int
    ) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        var seen = Set<String>()
        let model = parsed.model

        // Locals and parameters, innermost per name.
        let inScope = model.bindings.filter { $0.scopeStart <= byte && byte < $0.scopeEnd && !$0.nameBytes.isEmpty }
        var innermost: [String: SwiftFileModel.Binding] = [:]
        for binding in inScope {
            if let current = innermost[binding.name] {
                let span = binding.scopeEnd - binding.scopeStart
                let currentSpan = current.scopeEnd - current.scopeStart
                if span < currentSpan || (span == currentSpan && binding.scopeStart >= current.scopeStart) {
                    innermost[binding.name] = binding
                }
            } else {
                innermost[binding.name] = binding
            }
        }
        for binding in innermost.values where seen.insert(binding.name).inserted {
            let kind: CompletionItemKind
            switch binding.symbolKind {
            case .function: kind = .function
            case .type: kind = .type
            case .parameter, .local: kind = .variable
            }
            items.append(self.item(
                label: binding.name, kind: kind, detail: binding.typeText ?? binding.typeName ?? binding.signature,
                priority: binding.symbolKind == .parameter ? 28 : 30, context: context
            ))
        }

        // Members of the enclosing types, and what they inherit.
        let file = context.document.url
        for type in model.enclosingTypes(at: byte).reversed() {
            for ref in await index.members(ofType: type.name, visibleFrom: file)
            where ref.declaration.kind != .initializer && seen.insert(ref.declaration.name).inserted {
                items.append(memberItem(ref.declaration, owner: ref.owner, receiver: type.name, context: context, priority: 25))
            }
        }

        // The file's own top-level declarations, then every other project declaration.
        for declaration in model.declarations where declaration.kind != .extension && seen.insert(declaration.name).inserted {
            items.append(declarationItem(declaration, priority: 20, context: context))
        }
        let imported = Set(model.imports.map(\.module))
        for export in await index.exports(matching: context.prefix, limit: 120) where seen.insert(export.name).inserted {
            if export.url.standardizedFileURL == file?.standardizedFileURL { continue }
            var edits: [TextEdit] = []
            if let module = export.module, !imported.contains(module) {
                let currentModule = await index.module(of: file ?? URL(fileURLWithPath: "/"))
                if module != currentModule {
                    edits = importEdit(module: module, parsed: parsed)
                }
            }
            items.append(exportItem(export, edits: edits, context: context))
        }

        for snippet in Self.snippets where seen.insert(snippet.label).inserted {
            items.append(CompletionItem(
                label: snippet.label, insertText: snippet.text, kind: .snippet, range: context.range, source: name,
                detail: snippet.detail, insertTextIsSnippet: true, priority: 5, allowsAutoInsert: false
            ))
        }
        for keyword in Self.keywords where seen.insert(keyword).inserted {
            items.append(item(label: keyword, kind: .keyword, detail: nil, priority: 0, context: context))
        }
        for function in Self.globalFunctions where seen.insert(function.name).inserted {
            items.append(CompletionItem(
                label: function.name, insertText: function.text, kind: .function, range: context.range, source: name,
                detail: function.detail, insertTextIsSnippet: true, priority: 8, triggersSignatureHelp: true
            ))
        }
        return items
    }

    private func typeItems(parsed: SwiftParsed, resolver: SwiftResolver, context: CompletionContext) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        var seen = Set<String>()
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        for binding in parsed.model.bindings where binding.symbolKind == .type
            && binding.scopeStart <= byte && byte < binding.scopeEnd && seen.insert(binding.name).inserted {
            items.append(item(label: binding.name, kind: .type, detail: nil, priority: 30, context: context))
        }
        func visit(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations {
                if declaration.kind.isTypeLike, seen.insert(declaration.name).inserted {
                    items.append(typeItem(declaration, priority: 25, context: context))
                }
                if declaration.kind.isNominalType || declaration.kind == .extension { visit(declaration.members) }
            }
        }
        visit(parsed.model.declarations)
        let imported = Set(parsed.model.imports.map(\.module))
        let currentModule = await index.module(of: context.document.url ?? URL(fileURLWithPath: "/"))
        for export in await index.exports(matching: context.prefix, limit: 150)
        where export.kind.isTypeLike && seen.insert(export.name).inserted {
            var edits: [TextEdit] = []
            if let module = export.module, module != currentModule, !imported.contains(module) {
                edits = importEdit(module: module, parsed: parsed)
            }
            items.append(exportItem(export, edits: edits, context: context))
        }
        for name in Self.standardTypes where seen.insert(name).inserted {
            items.append(item(label: name, kind: .type, detail: nil, priority: 12, context: context))
        }
        for keyword in ["Self", "Any", "AnyObject", "Void", "some", "any"] where seen.insert(keyword).inserted {
            items.append(item(label: keyword, kind: .keyword, detail: nil, priority: 0, context: context))
        }
        return items
    }

    private func moduleItems(context: CompletionContext) async -> [CompletionItem] {
        var names = Set(Self.frameworks)
        for export in await index.exports(matching: "", limit: 400) {
            if let module = export.module { names.insert(module) }
        }
        return names.sorted().map { item(label: $0, kind: .module, detail: nil, priority: 10, context: context) }
    }

    // MARK: Items

    private func signatureKey(_ declaration: SwiftFileModel.Declaration) -> String {
        declaration.parameters.map { ($0.label ?? "_") + ":" }.joined()
    }

    private func memberItem(
        _ declaration: SwiftFileModel.Declaration, owner: String, receiver: String,
        context: CompletionContext, priority: Double = 25
    ) -> CompletionItem {
        let hasParameters = !declaration.parameters.isEmpty
        var insert = declaration.name
        var detail = declaration.typeText ?? declaration.typeName
        var labelDetail: String?
        var isSnippet = false
        let kind: CompletionItemKind

        func callText(_ base: String) {
            if hasParameters {
                let placeholders = declaration.parameters.enumerated().map { offset, parameter -> String in
                    let label = parameter.label.map { $0 + ": " } ?? ""
                    return "\(label)${\(offset + 1):\(parameter.name.isEmpty ? "value" : parameter.name)}"
                }
                insert = base + "(" + placeholders.joined(separator: ", ") + ")"
                isSnippet = true
            } else {
                insert = base + "()"
            }
            labelDetail = "(" + declaration.parameters.map { ($0.label ?? "_") + ":" }.joined() + ")"
        }

        switch declaration.kind {
        case .function:
            kind = .method
            callText(declaration.name)
        case .initializer:
            kind = .constructor
            callText("init")
            detail = receiver.isEmpty ? nil : receiver
        case .enumCase:
            kind = .enumMember
            if hasParameters { callText(declaration.name) }
            detail = receiver.isEmpty ? nil : receiver
        case .property:
            kind = .property
        case .typeAlias, .associatedType, .class, .struct, .enum, .actor, .protocol:
            kind = .type
        case .subscript, .deinitializer, .extension:
            kind = .method
        }
        return CompletionItem(
            label: declaration.kind == .initializer ? "init" : declaration.name, insertText: insert, kind: kind,
            range: context.range, source: name, documentation: declaration.docComment, detail: detail,
            labelDetail: labelDetail, insertTextIsSnippet: isSnippet, priority: priority,
            triggersSignatureHelp: hasParameters && declaration.kind != .enumCase,
            origin: owner.isEmpty || owner == receiver ? nil : owner
        )
    }

    private func standardItem(_ member: SwiftStandardLibrary.Member, context: CompletionContext) -> CompletionItem {
        CompletionItem(
            label: member.name, insertText: member.insertText,
            kind: member.kind == .property ? .property : .method, range: context.range, source: name,
            detail: member.returns, insertTextIsSnippet: member.isSnippet, priority: 22,
            triggersSignatureHelp: member.isSnippet
        )
    }

    private func declarationItem(
        _ declaration: SwiftFileModel.Declaration, priority: Double, context: CompletionContext
    ) -> CompletionItem {
        switch declaration.kind {
        case .function:
            return memberItem(declaration, owner: "", receiver: "", context: context, priority: priority)
        case .property:
            return item(
                label: declaration.name, kind: .variable, detail: declaration.typeText ?? declaration.typeName,
                priority: priority, context: context
            )
        default:
            return typeItem(declaration, priority: priority, context: context)
        }
    }

    private func typeItem(
        _ declaration: SwiftFileModel.Declaration, priority: Double, context: CompletionContext
    ) -> CompletionItem {
        CompletionItem(
            label: declaration.name, insertText: declaration.name, kind: completionKind(declaration.kind),
            range: context.range, source: name, documentation: declaration.docComment,
            detail: declaration.kind.rawValue, priority: priority
        )
    }

    private func exportItem(_ export: SwiftIndex.ExportRef, edits: [TextEdit], context: CompletionContext) -> CompletionItem {
        let kind: CompletionItemKind
        switch export.kind {
        case .function: kind = .function
        case .property: kind = .variable
        default: kind = completionKind(export.kind)
        }
        return CompletionItem(
            label: export.name, insertText: export.name, kind: kind, range: context.range, source: name,
            detail: export.module.map { "\($0) · \(export.kind.rawValue)" } ?? export.kind.rawValue,
            additionalEdits: edits, priority: edits.isEmpty ? 15 : 10
        )
    }

    private func item(
        label: String, kind: CompletionItemKind, detail: String?, priority: Double, context: CompletionContext
    ) -> CompletionItem {
        CompletionItem(
            label: label, insertText: label, kind: kind, range: context.range, source: name,
            detail: detail, priority: priority
        )
    }

    private func completionKind(_ kind: SwiftFileModel.Kind) -> CompletionItemKind {
        switch kind {
        case .class, .actor: return .class
        case .struct, .typeAlias, .associatedType, .extension: return .type
        case .enum: return .enum
        case .protocol: return .interface
        case .function, .subscript, .deinitializer: return .method
        case .initializer: return .constructor
        case .property: return .property
        case .enumCase: return .enumMember
        }
    }

    // MARK: Imports

    /// `import Module` after the last import, or at the top of the file past a leading comment block.
    private func importEdit(module: String, parsed: SwiftParsed) -> [TextEdit] {
        let statement = "import \(module)"
        if let last = parsed.model.imports.map(\.bytes.upperBound).max() {
            let position = parsed.text.position(atByte: last)
            return [TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: "\n" + statement)]
        }
        var insert = 0
        var cursor = 0
        let bytes = parsed.text.utf8
        // Skip a leading run of `//` comment lines (a license or tools-version header) and one blank line.
        while cursor < bytes.count {
            var lineEnd = cursor
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let line = String(decoding: bytes[cursor..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.isEmpty {
                cursor = min(lineEnd + 1, bytes.count)
                insert = cursor
                if line.isEmpty { break }
            } else {
                break
            }
        }
        let position = parsed.text.position(atByte: insert)
        return [TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: statement + "\n")]
    }

    // MARK: Tables

    private struct Snippet {
        var label: String
        var text: String
        var detail: String
    }

    private static let snippets: [Snippet] = [
        Snippet(label: "func", text: "func ${1:name}(${2}) {\n\t$0\n}", detail: "function"),
        Snippet(label: "if let", text: "if let ${1:value} = ${2:optional} {\n\t$0\n}", detail: "optional binding"),
        Snippet(label: "guard let", text: "guard let ${1:value} = ${2:optional} else {\n\t${3:return}\n}", detail: "early exit"),
        Snippet(label: "for in", text: "for ${1:item} in ${2:items} {\n\t$0\n}", detail: "loop"),
        Snippet(label: "switch", text: "switch ${1:value} {\ncase ${2:pattern}:\n\t$0\ndefault:\n\tbreak\n}", detail: "switch"),
        Snippet(label: "struct", text: "struct ${1:Name} {\n\t$0\n}", detail: "struct"),
        Snippet(label: "class", text: "class ${1:Name} {\n\t$0\n}", detail: "class"),
        Snippet(label: "enum", text: "enum ${1:Name} {\n\tcase ${2:value}\n}", detail: "enum"),
        Snippet(label: "extension", text: "extension ${1:Type} {\n\t$0\n}", detail: "extension"),
        Snippet(label: "protocol", text: "protocol ${1:Name} {\n\t$0\n}", detail: "protocol"),
        Snippet(label: "do catch", text: "do {\n\t${1:try }$0\n} catch {\n\t${2:print(error)}\n}", detail: "error handling"),
        Snippet(label: "init", text: "init(${1}) {\n\t$0\n}", detail: "initializer")
    ]

    private static let keywords: [String] = [
        "let", "var", "if", "else", "guard", "for", "while", "repeat", "return", "break", "continue", "case", "default",
        "import", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating",
        "throws", "throw", "try", "await", "async", "defer", "catch", "in", "is", "as", "self", "super", "nil",
        "true", "false", "where", "typealias", "associatedtype", "lazy", "weak", "unowned", "inout", "some", "any"
    ]

    private static let standardTypes: [String] = [
        "Int", "Double", "Float", "Bool", "String", "Character", "Array", "Dictionary", "Set", "Optional", "Data",
        "Date", "URL", "UUID", "Result", "Error", "Void", "CGFloat", "CGPoint", "CGSize", "CGRect"
    ]

    private static let frameworks: [String] = [
        "Foundation", "SwiftUI", "AppKit", "UIKit", "Combine", "CoreData", "CoreGraphics", "XCTest", "Testing",
        "os", "OSLog", "Dispatch", "Observation", "SwiftData", "Metal", "MetalKit", "AVFoundation", "WebKit",
        "Network", "CryptoKit", "PackageDescription", "ArgumentParser"
    ]

    private struct GlobalFunction {
        var name: String
        var text: String
        var detail: String
    }

    private static let globalFunctions: [GlobalFunction] = [
        GlobalFunction(name: "print", text: "print(${1:items})", detail: "Void"),
        GlobalFunction(name: "min", text: "min(${1:x}, ${2:y})", detail: "T"),
        GlobalFunction(name: "max", text: "max(${1:x}, ${2:y})", detail: "T"),
        GlobalFunction(name: "abs", text: "abs(${1:x})", detail: "T"),
        GlobalFunction(name: "zip", text: "zip(${1:sequence1}, ${2:sequence2})", detail: "Zip2Sequence"),
        GlobalFunction(name: "stride", text: "stride(from: ${1:start}, to: ${2:end}, by: ${3:step})", detail: "StrideTo"),
        GlobalFunction(name: "fatalError", text: "fatalError(${1:\"message\"})", detail: "Never"),
        GlobalFunction(name: "precondition", text: "precondition(${1:condition})", detail: "Void"),
        GlobalFunction(name: "assert", text: "assert(${1:condition})", detail: "Void")
    ]
}
