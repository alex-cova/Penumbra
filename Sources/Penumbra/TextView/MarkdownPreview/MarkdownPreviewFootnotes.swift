import Foundation

/// Custom `AttributedString` attribute marking a run as a footnote reference (`[^label]`, already
/// replaced with its resolved footnote number by the time this is attached). Not a link: it has no
/// URL and isn't clickable, but it needs its own attribute so ``MarkdownPreviewInlineStyler`` can
/// give it a raised, smaller rendering distinct from ordinary text or a real link.
enum MarkdownPreviewFootnoteMarkerAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "PenumbraMarkdownPreviewFootnoteMarker"
}

extension AttributeScopes {
    struct PenumbraMarkdownPreviewAttributes: AttributeScope {
        let footnoteMarker: MarkdownPreviewFootnoteMarkerAttribute
    }

    var penumbraMarkdownPreview: PenumbraMarkdownPreviewAttributes.Type { PenumbraMarkdownPreviewAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.PenumbraMarkdownPreviewAttributes, T>) -> T {
        self[T.self]
    }
}

/// Extracts GFM-style footnotes (`[^label]` inline references, `[^label]: body` definitions) from
/// markdown source before it ever reaches Foundation's `AttributedString(markdown:)` parser, which
/// has no concept of footnotes at all — a `[^1]:` line is otherwise swept up by
/// `MarkdownPreviewIntentWalker.linkReferenceDefinitions` (footnote labels start with `^`, which is
/// *not* excluded by that regex's `[^\]]` character class) and either vanishes or renders as a
/// mangled link-reference paragraph.
enum MarkdownPreviewFootnotes {
    struct Definition {
        var label: String
        var body: String
    }

    private static let definitionStart = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let fenceStart = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)
    private static let referencePattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

    // MARK: - Extraction

    /// Line-oriented, fence-aware scan of the whole document. A `[^label]:` line inside a fenced
    /// code block is left untouched (fence state is tracked independently of
    /// `MermaidFenceExtractor`, which only recognizes backtick fences, so this also protects `~~~`
    /// fences). A definition's body is its first line plus any indented (4-space/tab) or lazy
    /// continuation lines up to the next blank line, joined into a single paragraph — matching the
    /// common single-paragraph footnote authoring style rather than full nested-block bodies.
    ///
    /// Each consumed definition, however many source lines it spans, is replaced by exactly one
    /// blank line in the returned source, so the paragraph before and after it don't merge into one.
    static func extract(from source: String) -> (source: String, definitions: [Definition]) {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var definitions: [Definition] = []
        var fenceMarker: String?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let marker = fenceMarker {
                output.append(line)
                if isClosingFence(line, opening: marker) { fenceMarker = nil }
                index += 1
                continue
            }
            if isFenceLine(line) {
                fenceMarker = openingFenceMarker(line)
                output.append(line)
                index += 1
                continue
            }
            guard let (label, firstBody) = matchDefinitionStart(line) else {
                output.append(line)
                index += 1
                continue
            }

            var bodyParts: [String] = []
            let trimmedFirstBody = firstBody.trimmingCharacters(in: .whitespaces)
            if !trimmedFirstBody.isEmpty { bodyParts.append(trimmedFirstBody) }

            var consumed = 1
            var lookahead = index + 1
            while lookahead < lines.count {
                let next = lines[lookahead]
                if isBlank(next) { break }
                if isIndentedContinuation(next) {
                    bodyParts.append(next.trimmingCharacters(in: .whitespaces))
                    consumed += 1
                    lookahead += 1
                    continue
                }
                // Lazy continuation: a non-blank line that isn't itself a new definition or fence
                // start still belongs to this footnote's paragraph.
                if matchDefinitionStart(next) == nil, !isFenceLine(next) {
                    bodyParts.append(next.trimmingCharacters(in: .whitespaces))
                    consumed += 1
                    lookahead += 1
                    continue
                }
                break
            }

            definitions.append(Definition(label: label, body: bodyParts.joined(separator: " ")))
            output.append("")
            index += consumed
        }

        return (output.joined(separator: "\n"), definitions)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isIndentedContinuation(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func matchDefinitionStart(_ line: String) -> (label: String, body: String)? {
        let ns = line as NSString
        guard let match = definitionStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    private static func isFenceLine(_ line: String) -> Bool {
        let ns = line as NSString
        return fenceStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func openingFenceMarker(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " })
        guard let fenceChar = trimmed.first else { return "```" }
        return String(trimmed.prefix(while: { $0 == fenceChar }))
    }

    private static func isClosingFence(_ line: String, opening marker: String) -> Bool {
        guard let fenceChar = marker.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == fenceChar else { return false }
        let run = trimmed.prefix(while: { $0 == fenceChar })
        guard run.count >= marker.count else { return false }
        return trimmed.dropFirst(run.count).isEmpty
    }

    // MARK: - Numbering and inline substitution

    /// Renumbers every extracted definition by order of first inline reference across `blocks` (in
    /// document order), substitutes each `[^label]` reference with its resolved number tagged
    /// `footnoteMarker`, and builds the `MarkdownPreviewFootnote` entries for the trailing section.
    /// A reference to a label with no definition is left as literal text, so a typo stays visible
    /// rather than silently disappearing while editing. A definition nobody references is appended
    /// after the referenced ones instead of being dropped (GitHub drops it; silently deleting text
    /// an author may be mid-way through typing is worse in a live preview).
    static func numberReferences(
        in blocks: [MarkdownPreviewBlock],
        definitions: [Definition]
    ) -> (blocks: [MarkdownPreviewBlock], footnotes: [MarkdownPreviewFootnote]) {
        guard !definitions.isEmpty else { return (blocks, []) }

        var bodyForLabel: [String: String] = [:]
        var allLabelsInDefinitionOrder: [String] = []
        for definition in definitions where bodyForLabel[definition.label] == nil {
            bodyForLabel[definition.label] = definition.body
            allLabelsInDefinitionOrder.append(definition.label)
        }

        var numberForLabel: [String: Int] = [:]
        var referencedLabelsInOrder: [String] = []
        func number(for label: String) -> Int? {
            guard bodyForLabel[label] != nil else { return nil }
            if let existing = numberForLabel[label] { return existing }
            let next = numberForLabel.count + 1
            numberForLabel[label] = next
            referencedLabelsInOrder.append(label)
            return next
        }

        func substitute(_ text: AttributedString) -> AttributedString {
            substituteFootnoteReferences(in: text, numberFor: number(for:))
        }

        let newBlocks: [MarkdownPreviewBlock] = blocks.map { block in
            var block = block
            switch block.kind {
            case .heading(let level, let text):
                block.kind = .heading(level: level, text: substitute(text))
            case .paragraph(let text):
                block.kind = .paragraph(substitute(text))
            case .list(var list):
                for itemIndex in list.items.indices {
                    list.items[itemIndex].text = substitute(list.items[itemIndex].text)
                }
                block.kind = .list(list)
            case .table(var table):
                table.header = table.header.map(substitute)
                table.rows = table.rows.map { row in row.map(substitute) }
                block.kind = .table(table)
            default:
                break
            }
            return block
        }

        // Referenced labels already have numbers in first-reference order; give every remaining
        // (unreferenced) definition the next number, in definition order, before building entries —
        // so a footnote body citing another footnote sees a final, already-assigned number instead
        // of minting a new one out of order.
        var orderedLabels = referencedLabelsInOrder
        for label in allLabelsInDefinitionOrder where numberForLabel[label] == nil {
            numberForLabel[label] = numberForLabel.count + 1
            orderedLabels.append(label)
        }

        let entries: [MarkdownPreviewFootnote] = orderedLabels.compactMap { label in
            guard let body = bodyForLabel[label], let assignedNumber = numberForLabel[label] else { return nil }
            return MarkdownPreviewFootnote(number: assignedNumber, label: label, text: parseFootnoteBody(body, numberFor: number(for:)))
        }

        return (newBlocks, entries)
    }

    private static func parseFootnoteBody(_ markdown: String, numberFor: (String) -> Int?) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        return substituteFootnoteReferences(in: parsed, numberFor: numberFor)
    }

    /// Replaces every `[^label]` occurrence in `text` whose label resolves via `numberFor` with a
    /// run containing just its number, tagged `footnoteMarker`. An unresolved label is left as
    /// literal text.
    private static func substituteFootnoteReferences(
        in text: AttributedString,
        numberFor: (String) -> Int?
    ) -> AttributedString {
        let plain = String(text.characters)
        guard plain.contains("[^") else { return text }
        let ns = plain as NSString
        let matches = referencePattern.matches(in: plain, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        // Resolve numbers in left-to-right reading order first — `numberFor` assigns a label's
        // number the first time it's *seen*, and replacement below must happen back-to-front (to
        // keep not-yet-processed offsets, computed against the original `plain`, valid), which
        // would otherwise number labels in reverse order.
        let numbers: [Int?] = matches.map { match in
            numberFor(ns.substring(with: match.range(at: 1)))
        }

        var result = text
        for (match, resolvedNumber) in zip(matches, numbers).reversed() {
            guard let resolvedNumber else { continue }
            guard let swiftRange = Range(match.range, in: plain) else { continue }
            let startOffset = plain.distance(from: plain.startIndex, to: swiftRange.lowerBound)
            let endOffset = plain.distance(from: plain.startIndex, to: swiftRange.upperBound)
            let start = result.index(result.startIndex, offsetByCharacters: startOffset)
            let end = result.index(result.startIndex, offsetByCharacters: endOffset)

            var replacement = AttributedString("\(resolvedNumber)")
            replacement.footnoteMarker = resolvedNumber
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }
}
