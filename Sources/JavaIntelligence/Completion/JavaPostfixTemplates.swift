import EditorIntelligence
import Foundation

/// IntelliJ-style postfix completion: `flag.if` → `if (flag) { … }`, `items.for` →
/// `for (Item item : items) { … }`. Offered after `expr.` once a letter is typed, or with an
/// empty prefix when completion was asked for templates only.
///
/// Bodies are snippets (`$0` is the caret, `${1:name}` a tab stop). `$` in the receiver is
/// written `$$` so a receiver like `"a$b"` survives snippet parsing. Each item deletes `expr.`
/// in an additional edit, which the controller applies in the same undo group as the snippet.
struct JavaPostfixTemplates {
    let bytes: [UInt8]
    let dotOffset: Int
    let factory: JavaCompletionItemFactory
    let source: String
    let takenNames: Set<String>
    let configuration: JavaPostfixConfiguration
    let prefix: String
    let importer: JavaImportInserter

    func items(candidates: [JavaPostfixCandidate], imports: JavaPostfixImports) -> [CompletionItem] {
        guard configuration.isEnabled, !candidates.isEmpty else { return [] }
        var result: [CompletionItem] = []
        let outermostStarts = Self.startsStatement(bytes: bytes, at: candidates[candidates.count - 1].range.lowerBound)
        for (index, candidate) in candidates.enumerated() {
            let ownStart = Self.startsStatement(bytes: bytes, at: candidate.range.lowerBound)
            let startsStatement = ownStart || (outermostStarts && candidates.count > 1)
            emitBuiltins(
                candidate, index: index, count: candidates.count, startsStatement: startsStatement,
                imports: imports, into: &result
            )
        }
        emitCustom(candidates, into: &result)
        return result
    }

    func fieldItems(
        candidates: [JavaPostfixCandidate], source: String, fileURL: URL, index: JavaIndex
    ) async -> [CompletionItem] {
        guard configuration.allows("field"), prefix.isEmpty || "field".hasPrefix(prefix) else { return [] }
        let sourceBytes = Array(source.utf8)
        var result: [CompletionItem] = []
        for (position, candidate) in candidates.enumerated() where !candidate.isTypeReference && candidate.type != .void {
            let name = unique(Self.variableName(forExpression: candidate.text, type: candidate.type))
            let start = JavaImportInserter.textPosition(forByteOffset: candidate.range.lowerBound, in: sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: candidate.range.upperBound, in: sourceBytes)
            let selection = Selection(range: TextRange(start: start, end: end))
            // The live buffer stops at the typed key (`user.field`), which tree-sitter reads as a
            // type name. The repaired buffer (`user.field__penumbra__;`) is the parse completion
            // already uses, and every edit we keep sits before the dummy, so its offsets match
            // the live buffer.
            let plan = await JavaExtractField.plan(
                source: source, selection: selection, url: fileURL, name: name, index: index
            )
            guard !plan.isBlocked else { continue }
            var edits = plan.entries.filter { $0.description != "Replace expression" && !$0.isReadOnly }.map {
                TextEdit(range: $0.range, replacement: $0.newText)
            }
            edits.append(deleteReceiverEdit(candidate.range))
            add(
                "field", "Introduce field", "\(Self.snippetText(name))$0", edits: edits,
                expression: candidate.range, index: position, count: candidates.count, detail: candidate.text, into: &result
            )
        }
        return result
    }

    private func emitBuiltins(
        _ candidate: JavaPostfixCandidate, index: Int, count: Int, startsStatement: Bool,
        imports: JavaPostfixImports, into result: inout [CompletionItem]
    ) {
        if candidate.isTypeReference {
            guard configuration.allows("new"), JavaPostfixTypes.isReference(candidate.type) else { return }
            let diamond = candidate.hasTypeParameters ? "<>" : ""
            add(
                "new", "new expr()", "new \(escaped(candidate.text))\(diamond)($0)",
                expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
            )
            return
        }

        let expression = escaped(candidate.text)
        let wrapped = escaped(parenthesized(candidate.text))
        let indentation = Self.lineIndentation(bytes: bytes, at: candidate.range.lowerBound)
        let step = indentation.contains("\t") ? "\t" : "    "
        let inner = indentation + step
        let type = candidate.type
        let isBoolean = JavaPostfixTypes.isBoolean(type)
        let isReference = JavaPostfixTypes.isReference(type)
        let typeText = Self.sourceText(type)

        func block(_ header: String, caretOnInner: Bool = true) -> String {
            if caretOnInner {
                return "\(header) {\n\(inner)$0\n\(indentation)}"
            }
            return "\(header) {\n\(inner)\n\(indentation)}"
        }

        if isBoolean {
            if configuration.allows("not") {
                add("not", "!expr", "!\(wrapped)$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if startsStatement {
                if configuration.allows("if") {
                    add("if", "if (expr)", block("if (\(expression))"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
                if configuration.allows("else") {
                    add("else", "if (!expr)", block("if (!\(wrapped))"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
                if configuration.allows("while") {
                    add("while", "while (expr)", block("while (\(expression))"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
                if configuration.allows("assert") {
                    add("assert", "assert expr", "assert \(expression);$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
            }
        }

        if isReference {
            if configuration.allows("cast") {
                add("cast", "(Type) expr", "((${1:Object}) \(wrapped))$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if startsStatement, configuration.allows("castvar") {
                let name = unique(Self.variableName(forExpression: candidate.text, type: type))
                add(
                    "castvar", "Type name = (Type) expr",
                    "${1:Object} ${2:\(name)} = (${1:Object}) \(wrapped);$0",
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if startsStatement, configuration.allows("inst") || configuration.allows("instanceof") {
                let pattern = unique("t")
                let body = block("if (\(expression) instanceof ${1:T} ${2:\(pattern)})")
                if configuration.allows("inst") {
                    add("inst", "if (expr instanceof T t)", body, expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
                if configuration.allows("instanceof") {
                    add("instanceof", "if (expr instanceof T t)", body, expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
                }
            }
            if configuration.allows("opt") {
                add(
                    "opt", "Optional.ofNullable(expr)", "\(imports.optionalName).ofNullable(\(expression))$0",
                    edits: edits(imports.optionalEdit, candidate.range),
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if configuration.allows("reqnonnull") {
                add(
                    "reqnonnull", "Objects.requireNonNull(expr)", "\(imports.objectsName).requireNonNull(\(expression))$0",
                    edits: edits(imports.objectsEdit, candidate.range),
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if startsStatement, configuration.allows("synchronized") {
                add(
                    "synchronized", "synchronized (expr)", block("synchronized (\(expression))"),
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if configuration.allows("lambda") {
                add("lambda", "() -> expr", "() -> \(expression)$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
        }

        if type != .void {
            if configuration.allows("par") {
                add("par", "(expr)", "(\(expression))$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if configuration.allows("arg") {
                add("arg", "method(expr)", "${1:method}(\(expression))$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
        }

        guard startsStatement else { return }

        if isReference {
            if configuration.allows("nn") {
                add("nn", "if (expr != null)", block("if (\(expression) != null)"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if configuration.allows("null") {
                add("null", "if (expr == null)", block("if (\(expression) == null)"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
        }
        if let elementType = candidate.elementType, candidate.isIterable, configuration.allows("for") {
            let element = Self.sourceText(elementType)
            let name = unique(Self.elementName(forCollection: candidate.text, elementType: elementType))
            add(
                "for", "for (\(element) \(name) : expr)",
                block("for (\(element) ${1:\(name)} : \(expression))"),
                expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
            )
        }
        if configuration.allows("fori") {
            if type == .primitive(.int) || type == .primitive(.long) {
                let counter = type == .primitive(.long) ? "long" : "int"
                let indexName = unique("i")
                add(
                    "fori", "for (i < expr)",
                    block("for (\(counter) ${1:\(indexName)} = 0; ${1:\(indexName)} < \(expression); ${1:\(indexName)}++)"),
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            } else if case .array = type {
                let indexName = unique("i")
                add(
                    "fori", "for (i < expr.length)",
                    block("for (int ${1:\(indexName)} = 0; ${1:\(indexName)} < \(expression).length; ${1:\(indexName)}++)"),
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
        }
        if configuration.allows("forr") {
            if let body = reverseLoop(candidate, expression: expression, inner: inner, indentation: indentation) {
                add("forr", "for (i >= 0)", body, expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
        }
        if type != .void {
            if configuration.allows("var") {
                let name = unique(Self.variableName(forExpression: candidate.text, type: type))
                add(
                    "var", "\(typeText) name = expr", "\(typeText) ${1:\(name)} = \(expression);$0",
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if configuration.allows("return") {
                add("return", "return expr", "return \(expression);$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if configuration.allows("sout") {
                add("sout", "System.out.println(expr)", "System.out.println(\(expression));$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if configuration.allows("soutv") {
                let literal = Self.javaStringLiteral(candidate.text)
                add(
                    "soutv", "println(\"expr = \" + expr)",
                    "System.out.println(\"\(literal) = \" + \(expression));$0",
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
            if configuration.allows("serr") {
                add("serr", "System.err.println(expr)", "System.err.println(\(expression));$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
            }
            if configuration.allows("souf") {
                add(
                    "souf", "System.out.printf(expr)", "System.out.printf(\"${1:%s}\", \(expression));$0",
                    expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
                )
            }
        }
        if JavaPostfixTypes.isSwitchSelector(type, isEnum: candidate.isEnum), configuration.allows("switch") {
            add("switch", "switch (expr)", block("switch (\(expression))"), expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
        }
        if configuration.allows("try"), type != .void {
            let caught = unique("e")
            let body = """
            try {
            \(inner)\(expression);
            \(indentation)} catch (${1:Exception} ${2:\(caught)}) {
            \(inner)$0
            \(indentation)}
            """
            add("try", "try / catch", body, expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
        }
        if case .array = type, configuration.allows("stream") {
            add(
                "stream", "Arrays.stream(expr)", "\(imports.arraysName).stream(\(expression))$0",
                edits: edits(imports.arraysEdit, candidate.range),
                expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
            )
        }
        if type.erasedQualifiedName == "java.lang.String", configuration.allows("format") {
            add("format", "String.format(expr)", "String.format(\(expression), $0)", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
        }
        if candidate.isThrowable, configuration.allows("throw") {
            add("throw", "throw expr", "throw \(expression);$0", expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result)
        }
        if candidate.isAutoCloseable, configuration.allows("twr") {
            let name = unique(Self.variableName(forExpression: candidate.text, type: type))
            add(
                "twr", "try (expr)",
                block("try (\(typeText) ${1:\(name)} = \(expression))"),
                expression: candidate.range, index: index, count: count, detail: candidate.text, into: &result
            )
        }
    }

    private func reverseLoop(
        _ candidate: JavaPostfixCandidate, expression: String, inner: String, indentation: String
    ) -> String? {
        let indexName = unique("i")
        let header: String
        let stepLine: String?
        if case .array = candidate.type {
            header = "for (int ${1:\(indexName)} = \(expression).length - 1; ${1:\(indexName)} >= 0; ${1:\(indexName)}--)"
            let element = Self.sourceText(candidate.elementType ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil))
            let name = unique(Self.elementName(forCollection: candidate.text, elementType: candidate.elementType ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)), reserving: [indexName])
            stepLine = "\(element) ${2:\(name)} = \(expression)[${1:\(indexName)}];"
        } else if candidate.type == .primitive(.int) || candidate.type == .primitive(.long) {
            let counter = candidate.type == .primitive(.long) ? "long" : "int"
            let bound = escaped(parenthesized(candidate.text))
            header = "for (\(counter) ${1:\(indexName)} = \(bound) - 1; ${1:\(indexName)} >= 0; ${1:\(indexName)}--)"
            stepLine = nil
        } else if candidate.isList {
            header = "for (int ${1:\(indexName)} = \(expression).size() - 1; ${1:\(indexName)} >= 0; ${1:\(indexName)}--)"
            let element = Self.sourceText(candidate.elementType ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil))
            let name = unique(Self.elementName(forCollection: candidate.text, elementType: candidate.elementType ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)), reserving: [indexName])
            stepLine = "\(element) ${2:\(name)} = \(expression).get(${1:\(indexName)});"
        } else {
            return nil
        }
        if let stepLine {
            return """
            \(header) {
            \(inner)\(stepLine)
            \(inner)$0
            \(indentation)}
            """
        }
        return """
        \(header) {
        \(inner)$0
        \(indentation)}
        """
    }

    private func emitCustom(_ candidates: [JavaPostfixCandidate], into result: inout [CompletionItem]) {
        for template in configuration.customTemplates where !template.key.isEmpty && configuration.allows(template.key) {
            let pairs: [(Int, JavaPostfixCandidate)]
            if template.topmost, let last = candidates.indices.last {
                pairs = [(last, candidates[last])]
            } else {
                pairs = Array(candidates.enumerated())
            }
            for (index, candidate) in pairs where candidate.matchingCustom.contains(where: { $0.id == template.id }) {
                var edits = [deleteReceiverEdit(candidate.range)]
                var body = template.body.replacingOccurrences(of: "$EXPR$", with: escaped(candidate.text))
                if template.useStaticImport {
                    body = shortenStaticCall(in: body, edits: &edits)
                }
                add(
                    template.key, template.key, body, edits: edits,
                    expression: candidate.range, index: index, count: candidates.count, detail: candidate.text, into: &result
                )
            }
        }
    }

    /// `pkg.Class.member(` → `member(` plus a static import, unless that simple name is already taken.
    private func shortenStaticCall(in body: String, edits: inout [TextEdit]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b((?:[a-z_]\w*\.)+[A-Z]\w*)\.(\w+)\s*\("#) else { return body }
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: body, range: full), match.numberOfRanges >= 3 else { return body }
        let owner = ns.substring(with: match.range(at: 1))
        let member = ns.substring(with: match.range(at: 2))
        let qualifier = NSRange(location: match.range(at: 1).location, length: match.range(at: 1).length + 1)
        switch importer.decisionForStaticMember(owner: owner, member: member) {
        case .useQualifiedName:
            return body
        case .none:
            return ns.replacingCharacters(in: qualifier, with: "")
        case .addImport(let edit):
            edits.append(edit)
            return ns.replacingCharacters(in: qualifier, with: "")
        }
    }

    private func add(
        _ label: String, _ description: String, _ body: String, edits: [TextEdit]? = nil,
        expression: Range<Int>, index: Int, count: Int, detail: String, into result: inout [CompletionItem]
    ) {
        let boost = count > 1 ? Double(count - index) * 0.01 : 0
        result.append(CompletionItem(
            label: label, insertText: body, kind: .snippet, range: factory.range, source: source,
            filterText: label, detail: description,
            labelDetail: count > 1 ? detail : nil,
            additionalEdits: edits ?? [deleteReceiverEdit(expression)],
            priority: JavaCompletionPriority.keyword + boost,
            allowsAutoInsert: false
        ))
    }

    private func edits(_ importEdit: TextEdit?, _ expression: Range<Int>) -> [TextEdit] {
        var edits = [deleteReceiverEdit(expression)]
        if let importEdit { edits.append(importEdit) }
        return edits
    }

    private func escaped(_ expression: String) -> String {
        Self.snippetText(expression)
    }

    /// A receiver written into a snippet: a literal `$` is `$$`.
    static func snippetText(_ expression: String) -> String {
        expression.replacingOccurrences(of: "$", with: "$$")
    }

    /// The receiver as a Java string literal's contents, then snippet-escaped.
    static func javaStringLiteral(_ expression: String) -> String {
        var literal = ""
        for character in expression {
            switch character {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            default: literal.append(character)
            }
        }
        return snippetText(literal)
    }

    /// A type as the generated code writes it: simple names, with nested types kept behind their
    /// outer type (`Map.Entry<String, User>`), since an on-demand import doesn't bring a nested
    /// type into scope.
    static func sourceText(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, let arguments, _):
            let segments = name.split(separator: ".").map(String.init)
            let firstType = segments.firstIndex { $0.first?.isUppercase == true } ?? max(0, segments.count - 1)
            let base = segments[firstType...].joined(separator: ".")
            guard !arguments.isEmpty else { return base }
            return "\(base)<\(arguments.map(sourceText).joined(separator: ", "))>"
        case .array(let element):
            return "\(sourceText(element))[]"
        default:
            return JavaCompletionItemFactory.display(type)
        }
    }

    private static func sourceText(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type): return sourceText(type)
        case .wildcard(nil): return "?"
        case .wildcard(.extends(let type)?): return "? extends \(sourceText(type))"
        case .wildcard(.superBound(let type)?): return "? super \(sourceText(type))"
        }
    }

    private func unique(_ name: String, reserving extra: Set<String> = []) -> String {
        let taken = takenNames.union(extra)
        guard taken.contains(name) else { return name }
        var counter = 1
        while taken.contains("\(name)\(counter)") { counter += 1 }
        return "\(name)\(counter)"
    }

    static func elementName(forCollection collection: String, elementType: JavaTypeRef) -> String {
        let last = String(collection.split(separator: ".").last ?? Substring(collection))
        if last.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            if last.hasSuffix("ies"), last.count > 3 { return String(last.dropLast(3)) + "y" }
            if last.hasSuffix("s"), !last.hasSuffix("ss"), last.count > 1 { return String(last.dropLast()) }
        }
        return variableName(forType: elementType, avoiding: collection)
    }

    /// Parentheses around an operator expression. A call, a name, or a field access stays bare.
    private func parenthesized(_ expression: String) -> String {
        expression.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "(" || $0 == ")" } ? expression : "(\(expression))"
    }

    private func deleteReceiverEdit(_ expression: Range<Int>) -> TextEdit {
        TextEdit(
            range: TextRange(start: position(ofByte: expression.lowerBound), end: position(ofByte: dotOffset + 1)),
            replacement: ""
        )
    }

    private func position(ofByte offset: Int) -> TextPosition {
        let prefix = String(decoding: bytes[0..<min(offset, bytes.count)], as: UTF8.self)
        let utf16 = (prefix as NSString).length
        var line = 0
        var lineStart = prefix.startIndex
        for index in prefix.indices where prefix[index] == "\n" {
            line += 1
            lineStart = prefix.index(after: index)
        }
        return TextPosition(line: line, column: prefix[lineStart...].utf16.count, utf16Offset: utf16)
    }

    static func startsStatement(bytes: [UInt8], at offset: Int) -> Bool {
        let before = JavaReceiverScanner.skipTrivia(bytes, before: offset) ?? offset
        guard before > 0 else { return true }
        return [UInt8(ascii: ";"), UInt8(ascii: "{"), UInt8(ascii: "}")].contains(bytes[before - 1])
    }

    static func lineIndentation(bytes: [UInt8], at offset: Int) -> String {
        var lineStart = min(offset, bytes.count)
        while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    static func variableName(forExpression expression: String, type: JavaTypeRef) -> String {
        let lastSegment = expression.split(separator: ".").last.map(String.init) ?? expression
        let call = lastSegment.prefix { $0 != "(" }
        for prefix in ["get", "is"] where call.hasPrefix(prefix) && call.count > prefix.count {
            let rest = call.dropFirst(prefix.count)
            if rest.first?.isUppercase == true { return rest.prefix(1).lowercased() + rest.dropFirst() }
        }
        return variableName(forType: type, avoiding: expression)
    }

    static func variableName(forType type: JavaTypeRef, avoiding taken: String) -> String {
        var name: String
        switch type {
        case .primitive(let primitive): name = String(primitive.rawValue.prefix(1))
        case .array(let element): name = variableName(forType: element, avoiding: taken) + "s"
        default:
            let simple = JavaCompletionItemFactory.display(type).prefix { $0 != "<" }
            name = simple.prefix(1).lowercased() + simple.dropFirst()
        }
        if name.isEmpty || name == taken || JavaCompletionProvider.keywords.contains(name) { name += "1" }
        return name
    }
}
