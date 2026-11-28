@preconcurrency import AppKit
import EditorIntelligence

/// An inlay hint in the coordinates of one line: where it sits and how much room it takes.
struct LineInlayHint: Equatable {
    /// Line-local UTF-16 offset of the character the hint is in front of. The room for a hint is
    /// added after the character before it, so it is at least 1 except for a hint at the first
    /// character of the line (0): that one has no character before it, and the line's first
    /// fragment reserves ``leadingInset(of:)`` in front of the text instead.
    let localOffset: Int
    let label: String
    let kind: InlayHint.Kind
    /// Everything the hint adds to the line: its padding, its text and the gap before the next
    /// character.
    let width: CGFloat
    /// Width of the items drawn after this one at the same document anchor.
    var followingWidth: CGFloat = 0
    var leadingPadding: CGFloat = 0

    /// X of the hint's room in the coordinates of the text (the first character's leading edge is 0).
    /// A line-start chip sits wholly left of the text, in the fragment's leading inset.
    func leadingX(in line: CTLine) -> CGFloat {
        // At the line's first character everything sits left of the text: a chip, then ghost text.
        guard localOffset > 0 else { return -(width + followingWidth) }
        return InlayChipGeometry.chipEnd(forLocalOffset: localOffset, in: line) - width - followingWidth
    }
    /// How the hint is painted. Part of the hint, so a theme or font change repaints (and re-typesets)
    /// the lines that have hints and nothing else.
    let appearance: InlayHintAppearance

    /// The UTF-16 offset into ``label`` of the character drawn at `x` (0 is the left edge of the label's
    /// text, inside the chip's padding), or nil when `x` is outside the text.
    func labelOffset(atTextX x: CGFloat) -> Int? {
        let text = label as NSString
        guard x >= 0, text.length > 0, x < appearance.textWidth(of: label) else { return nil }
        // The first offset whose character ends past `x`: widths only grow with the prefix.
        var low = 0
        var high = text.length - 1
        while low < high {
            let middle = (low + high) / 2
            if appearance.textWidth(of: text.substring(to: middle + 1)) > x { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Room the first fragment of a line reserves in front of its text for what sits at the line's first
    /// character: a chip and then ghost text, as in the middle of a line, or 0.
    static func leadingInset(of hints: [LineInlayHint]) -> CGFloat {
        hints.reduce(0) { $0 + ($1.localOffset == 0 ? $1.width : 0) }
    }

    /// The part of that room a semantic chip fills. The caret sits behind it and in front of ghost text.
    static func leadingChipWidth(of hints: [LineInlayHint]) -> CGFloat {
        hints.reduce(0) { $0 + ($1.localOffset == 0 && $1.kind != .inlineCompletion ? $1.width : 0) }
    }
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
    /// Editor font at full size, for inline completion ghost text.
    var editorFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Ghost text color: the theme's inline completion color, or its comment color.
    var inlineTextColor: NSColor = .secondaryLabelColor

    /// The look before a theme is applied: system UI font, system label colors.
    /// Main-actor only: `NSFont` and `NSColor` are not `Sendable`, and this value only seeds UI state.
    @MainActor
    static let standard = InlayHintAppearance(
        font: .systemFont(ofSize: 11),
        textColor: .secondaryLabelColor,
        backgroundColor: NSColor.labelColor.withAlphaComponent(0.09)
    )

    /// Sized from the editor font so hints follow its zoom: the editor font one point smaller, or the
    /// system UI font two points smaller (about what 13 pt code gets today). Colors are the theme's
    /// ``Theme/inlayHintTextColor`` / ``Theme/inlayHintBackgroundColor``, else shades of its text color.
    ///
    /// `sizeAdjustment` (points, clamped to the hint font staying between 7 and 24) and `backgroundOpacity`
    /// (a multiplier of the chip background's alpha: 0 draws none, 1 is the theme's) are the user's.
    static func make(
        theme: Theme, useEditorFont: Bool, sizeAdjustment: CGFloat = 0, backgroundOpacity: CGFloat = 1
    ) -> InlayHintAppearance {
        let editorFont = theme.font
        let font: NSFont
        if useEditorFont {
            let size = min(max(editorFont.pointSize - 1 + sizeAdjustment, 7), 24)
            font = NSFont(descriptor: editorFont.fontDescriptor, size: size) ?? editorFont
        } else {
            font = .systemFont(ofSize: min(max(editorFont.pointSize - 2 + sizeAdjustment, 7), 24))
        }
        var background = theme.inlayHintBackgroundColor ?? theme.textColor.withAlphaComponent(0.09)
        if backgroundOpacity != 1 {
            background = background.withAlphaComponent(min(max(background.alphaComponent * max(backgroundOpacity, 0), 0), 1))
        }
        return InlayHintAppearance(
            font: font,
            textColor: theme.inlayHintTextColor ?? theme.textColor.withAlphaComponent(0.55),
            backgroundColor: background,
            editorFont: editorFont,
            inlineTextColor: theme.inlineCompletionTextColor
                ?? theme.textColor(for: "comment")
                ?? theme.textColor.withAlphaComponent(0.45)
        )
    }

    func textWidth(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    func inlineTextWidth(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: editorFont]).width)
    }

    func width(of hint: InlayHint) -> CGFloat {
        width(of: hint.label, kind: hint.kind)
            + (hint.paddingLeft ? Self.trailingGap : 0)
            + (hint.paddingRight ? Self.trailingGap : 0)
    }

    /// The horizontal room a hint needs.
    func width(of label: String) -> CGFloat {
        textWidth(of: label) + Self.horizontalPadding * 2 + Self.trailingGap
    }

    /// The horizontal room a hint of `kind` needs: ghost text has no padding or gap.
    func width(of label: String, kind: InlayHint.Kind) -> CGFloat {
        kind == .inlineCompletion ? inlineTextWidth(of: label) : width(of: label)
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
            if let last = result.last, last.utf16Offset == hint.utf16Offset,
               last.kind != .inlineCompletion, hint.kind != .inlineCompletion {
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
    /// normalized. A hint at the very start of the line has no character before it to widen, so it
    /// is local offset 0 and the line's first fragment reserves room for it (see
    /// ``LineInlayHint/leadingInset(of:)``).
    static func localHints(
        in hints: [InlayHint],
        lineLocation location: Int,
        lineLength length: Int,
        appearance: InlayHintAppearance,
        measure: ((InlayHint) -> CGFloat)? = nil
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
        // Hints at the very start of the line have no character before them to widen, so the first
        // fragment reserves their room in front of the text: a chip first, then ghost text.
        var firstAtStart = low
        while firstAtStart > 0, hints[firstAtStart - 1].utf16Offset == location { firstAtStart -= 1 }
        let atStart = hints[firstAtStart..<low]
        for hint in atStart.filter({ $0.kind != .inlineCompletion }) + atStart.filter({ $0.kind == .inlineCompletion }) {
            result.append(LineInlayHint(
                localOffset: 0, label: hint.label, kind: hint.kind,
                width: measure?(hint) ?? appearance.width(of: hint),
                leadingPadding: hint.kind != .inlineCompletion && hint.paddingLeft ? InlayHintAppearance.trailingGap : 0,
                appearance: appearance
            ))
        }
        var index = low
        while index < hints.count, hints[index].utf16Offset <= location + length {
            let hint = hints[index]
            result.append(LineInlayHint(
                localOffset: hint.utf16Offset - location,
                label: hint.label,
                kind: hint.kind,
                width: measure?(hint) ?? appearance.width(of: hint),
                leadingPadding: hint.paddingLeft ? InlayHintAppearance.trailingGap : 0,
                appearance: appearance
            ))
            index += 1
        }
        var followingWidth: CGFloat = 0
        var offset: Int?
        for index in result.indices.reversed() {
            if result[index].localOffset != offset {
                offset = result[index].localOffset
                followingWidth = 0
            }
            result[index].followingWidth = followingWidth
            followingWidth += result[index].width
        }
        return result
    }

    /// `hints` after `range` was replaced by text of `replacementLength`: those after it move,
    /// those inside it go, since what they pointed at is gone.
    static func applyingEdit(to hints: [InlayHint], range: NSRange, replacementLength: Int) -> [InlayHint] {
        guard !hints.isEmpty else { return hints }
        let delta = replacementLength - range.length
        return hints.compactMap { hint in
            if hint.utf16Offset < range.location { return hint }
            if hint.utf16Offset == range.location {
                guard hint.affinity == .afterInsertion else { return hint }
                guard range.length == 0 else { return nil }
            }
            if hint.utf16Offset < range.upperBound { return nil }
            return hint.anchored(at: hint.utf16Offset + delta)
        }
    }
}
