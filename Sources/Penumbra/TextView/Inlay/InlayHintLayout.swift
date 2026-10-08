@preconcurrency import AppKit
import EditorIntelligence

/// An inlay hint in the coordinates of one line: where it sits and how much room it takes.
struct LineInlayHint: Equatable {
    /// Line-local UTF-16 offset of the character the hint is in front of. Always at least 1: the
    /// room for the hint is added after the character before it.
    let localOffset: Int
    let label: String
    let kind: InlayHint.Kind
    /// Everything the hint adds to the line: its padding, its text and the gap before the next
    /// character.
    let width: CGFloat
    /// How the hint is painted. Part of the hint, so a theme or font change repaints (and re-typesets)
    /// the lines that have hints and nothing else.
    let appearance: InlayHintAppearance
}

/// Look and metrics of inlay hints, shared by both paint paths. One value per text view, made
/// when the theme or the font choice changes (see ``make(theme:useEditorFont:)``).
struct InlayHintAppearance: Equatable {
    static let horizontalPadding: CGFloat = 3
    /// Space between the hint and the character it precedes.
    static let trailingGap: CGFloat = 3

    var font: NSFont
    var textColor: NSColor
    var backgroundColor: NSColor

    /// The look before a theme is applied: system UI font, system label colors.
    static let standard = InlayHintAppearance(
        font: .systemFont(ofSize: 11),
        textColor: .secondaryLabelColor,
        backgroundColor: NSColor.labelColor.withAlphaComponent(0.09)
    )

    /// Sized from the editor font so hints follow its zoom: the editor font one point smaller, or the
    /// system UI font two points smaller (about what 13 pt code gets today). Colors are the theme's
    /// ``Theme/inlayHintTextColor`` / ``Theme/inlayHintBackgroundColor``, else shades of its text color.
    static func make(theme: Theme, useEditorFont: Bool) -> InlayHintAppearance {
        let editorFont = theme.font
        let font: NSFont
        if useEditorFont {
            font = NSFont(descriptor: editorFont.fontDescriptor, size: max(editorFont.pointSize - 1, 8)) ?? editorFont
        } else {
            font = .systemFont(ofSize: max(editorFont.pointSize - 2, 9))
        }
        return InlayHintAppearance(
            font: font,
            textColor: theme.inlayHintTextColor ?? theme.textColor.withAlphaComponent(0.55),
            backgroundColor: theme.inlayHintBackgroundColor ?? theme.textColor.withAlphaComponent(0.09)
        )
    }

    func textWidth(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The horizontal room a hint needs.
    func width(of label: String) -> CGFloat {
        textWidth(of: label) + Self.horizontalPadding * 2 + Self.trailingGap
    }
}

/// Where a hint's room really is on a line. A hint widens the kern of the character before it, and
/// Core Text's index offsets are unreliable across a kern: inside a line `CTLineGetOffsetForStringIndex`
/// returns the middle of the gap, and at the end of a line the position before the gap. The glyph
/// positions are exact, so the room is measured from the leading edge of the glyph the hint precedes.
enum InlayChipGeometry {
    /// X where the hint's room ends and the next character begins: the leading edge of the glyph
    /// at `offset`, or the end of the line when the hint sits after its last character.
    static func chipEnd(forLocalOffset offset: Int, in line: CTLine) -> CGFloat {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            let range = CTRunGetStringRange(run)
            guard count > 0, offset >= range.location, offset < range.location + range.length else {
                continue
            }
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            if let glyph = indices.firstIndex(of: offset) {
                return positions[glyph].x
            }
        }
        let end = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let fallback = CTLineGetOffsetForStringIndex(line, offset, nil)
        // Past the last glyph the offset stops in front of the room; the line's width includes it.
        return offset >= CTLineGetStringRange(line).location + CTLineGetStringRange(line).length ? end : fallback
    }
}

enum InlayHintIndex {
    /// Sorts `hints`, merges those at one offset (their labels joined by a space) and drops
    /// negative offsets and empty labels.
    static func normalized(_ hints: [InlayHint]) -> [InlayHint] {
        var result: [InlayHint] = []
        let usable = hints.filter { $0.utf16Offset >= 0 && !$0.label.isEmpty }
        for hint in usable.sorted(by: { $0.utf16Offset < $1.utf16Offset }) {
            if let last = result.last, last.utf16Offset == hint.utf16Offset {
                result[result.count - 1] = InlayHint(
                    utf16Offset: last.utf16Offset, label: last.label + " " + hint.label, kind: last.kind
                )
            } else {
                result.append(hint)
            }
        }
        return result
    }

    /// The hints of a line covering `[location, location + length]`, line-local. `hints` must be
    /// normalized. A hint at the very start of the line has no character before it to widen and
    /// is not shown.
    static func localHints(
        in hints: [InlayHint],
        lineLocation location: Int,
        lineLength length: Int,
        appearance: InlayHintAppearance
    ) -> [LineInlayHint] {
        guard !hints.isEmpty else { return [] }
        // First hint strictly after the line's first character.
        var low = 0
        var high = hints.count
        while low < high {
            let mid = (low + high) / 2
            if hints[mid].utf16Offset <= location { low = mid + 1 } else { high = mid }
        }
        var result: [LineInlayHint] = []
        var index = low
        while index < hints.count, hints[index].utf16Offset <= location + length {
            let hint = hints[index]
            result.append(LineInlayHint(
                localOffset: hint.utf16Offset - location,
                label: hint.label,
                kind: hint.kind,
                width: appearance.width(of: hint.label),
                appearance: appearance
            ))
            index += 1
        }
        return result
    }

    /// `hints` after `range` was replaced by text of `replacementLength`: those after it move,
    /// those inside it go, since what they pointed at is gone.
    static func applyingEdit(to hints: [InlayHint], range: NSRange, replacementLength: Int) -> [InlayHint] {
        guard !hints.isEmpty else { return hints }
        let delta = replacementLength - range.length
        return hints.compactMap { hint in
            if hint.utf16Offset <= range.location { return hint }
            if hint.utf16Offset < range.upperBound { return nil }
            return InlayHint(utf16Offset: hint.utf16Offset + delta, label: hint.label, kind: hint.kind)
        }
    }
}
