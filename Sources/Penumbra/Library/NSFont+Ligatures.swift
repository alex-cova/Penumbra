import AppKit
import CoreText

public extension NSFont {
    /// This font with programming ligatures (`calt` and `liga`) turned on or off.
    ///
    /// Core Text applies them by default. Coding fonts such as JetBrains Mono and Fira Code build
    /// them from contextual alternates, so `NSAttributedString.Key.ligature` alone does not turn
    /// them off. The feature settings travel with the font descriptor, so fonts derived from the
    /// result (bold, italic, scaled headings) keep the choice.
    func withLigatures(_ enabled: Bool) -> NSFont {
        let contextual = enabled ? kContextualAlternatesOnSelector : kContextualAlternatesOffSelector
        let common = enabled ? kCommonLigaturesOnSelector : kCommonLigaturesOffSelector
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: Int(contextual)],
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: Int(common)]
        ]
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
