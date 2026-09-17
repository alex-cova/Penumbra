import CoreText
import Foundation
@preconcurrency import AppKit

/// Shared, side-effect-free resolution of which invisible-character symbols and warning borders a
/// line fragment needs, and where they sit horizontally (fragment-local X, in points).
///
/// `LineFragmentRenderer` (Core Graphics) and `MetalDecorationBuilder` both consume this so the two
/// paint paths cannot drift on *which* markers appear or *where*.
struct InvisibleCharacterLayout {
    struct Mark: Equatable {
        var string: String
        /// `nil` means "use `InvisibleCharacterConfiguration.textColor`".
        var color: UIColor?
        /// Fragment-local X in points (already `CTLine`-resolved).
        var x: CGFloat
        var isEndOfLine: Bool
    }

    struct WarningBorder: Equatable {
        var x: CGFloat
    }

    var symbols: [Mark]
    var warnings: [WarningBorder]

    var isEmpty: Bool {
        symbols.isEmpty && warnings.isEmpty
    }

    static let empty = InvisibleCharacterLayout(symbols: [], warnings: [])

    /// - Parameters:
    ///   - fragmentString: the fragment's visible substring (`LineController.string(in:)`).
    ///   - lineFragment: the fragment being laid out; used for `CTLine` X lookups.
    ///   - configuration: the live invisible-character configuration.
    static func resolve(
        fragmentString: String,
        lineFragment: LineFragment,
        configuration: InvisibleCharacterConfiguration
    ) -> InvisibleCharacterLayout {
        let showsAnySymbol = configuration.showTabs
            || configuration.showSpaces
            || configuration.showNonBreakingSpaces
            || configuration.showLineBreaks
            || configuration.showSoftLineBreaks
        guard showsAnySymbol || !configuration.warningCharacters.isEmpty else {
            return .empty
        }
        let endOfLineX = CGFloat(CTLineGetTypographicBounds(lineFragment.line, nil, nil, nil))
        func characterX(_ lineLocalIndex: Int) -> CGFloat {
            CTLineGetOffsetForStringIndex(lineFragment.line, lineLocalIndex, nil)
        }

        var symbols: [Mark] = []
        var warnings: [WarningBorder] = []
        var indexInLineFragment = 0
        for substring in fragmentString {
            let indexInLine = lineFragment.visibleRange.location + indexInLineFragment
            indexInLineFragment += substring.utf16.count
            let isWarningCharacter = configuration.warningCharacters.contains(substring)
            if isWarningCharacter {
                warnings.append(WarningBorder(x: characterX(indexInLine)))
            }
            if configuration.showSpaces && substring == Symbol.Character.space {
                symbols.append(Mark(string: configuration.spaceSymbol, color: nil, x: characterX(indexInLine), isEndOfLine: false))
            } else if configuration.showNonBreakingSpaces && substring == Symbol.Character.nonBreakingSpace {
                symbols.append(Mark(string: configuration.nonBreakingSpaceSymbol, color: nil, x: characterX(indexInLine), isEndOfLine: false))
            } else if configuration.showTabs && substring == Symbol.Character.tab {
                symbols.append(Mark(string: configuration.tabSymbol, color: nil, x: characterX(indexInLine), isEndOfLine: false))
            } else if configuration.showLineBreaks && isLineBreak(substring) {
                symbols.append(Mark(string: configuration.lineBreakSymbol, color: nil, x: endOfLineX, isEndOfLine: true))
            } else if configuration.showSoftLineBreaks && substring == Symbol.Character.lineSeparator {
                symbols.append(Mark(string: configuration.softLineBreakSymbol, color: nil, x: endOfLineX, isEndOfLine: true))
            } else if isWarningCharacter {
                symbols.append(Mark(string: String(substring), color: configuration.warningBorderColor, x: characterX(indexInLine), isEndOfLine: false))
            }
        }
        return InvisibleCharacterLayout(symbols: symbols, warnings: warnings)
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character == Symbol.Character.lineFeed
            || character == Symbol.Character.carriageReturn
            || character == Symbol.Character.carriageReturnLineFeed
    }
}
