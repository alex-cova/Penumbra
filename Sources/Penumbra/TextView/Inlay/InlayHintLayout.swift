@preconcurrency import AppKit
import EditorIntelligence

/// An inlay hint in the coordinates of one line: where it sits and how much room it takes.
struct LineInlayHint: Equatable {
    /// Line-local UTF-16 offset of the character the hint is in front of. Always at least 1: the
    /// room for the hint is added after the character before it.
    let localOffset: Int
    let label: String
    /// Everything the hint adds to the line: its padding, its text and the gap before the next
    /// character.
    let width: CGFloat
}

/// Look and metrics of inlay hints, shared by both paint paths.
enum InlayHintStyle {
    static let horizontalPadding: CGFloat = 3
    /// Space between the hint and the character it precedes.
    static let trailingGap: CGFloat = 3

    static var font: NSFont { .systemFont(ofSize: 11) }
    static var textColor: NSColor { .secondaryLabelColor }
    static var backgroundColor: NSColor { NSColor.labelColor.withAlphaComponent(0.09) }

    static func textWidth(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The horizontal room a hint needs.
    static func width(of label: String) -> CGFloat {
        textWidth(of: label) + horizontalPadding * 2 + trailingGap
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
    static func localHints(in hints: [InlayHint], lineLocation location: Int, lineLength length: Int) -> [LineInlayHint] {
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
                localOffset: hint.utf16Offset - location, label: hint.label, width: InlayHintStyle.width(of: hint.label)
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
