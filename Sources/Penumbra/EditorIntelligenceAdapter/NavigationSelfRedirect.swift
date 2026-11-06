import EditorIntelligence
import Foundation

/// Language-neutral rule for a Go to Definition answer that is the queried identifier itself.
///
/// Since J6, `JavaGoToDefinition.resolve` answers a click on a declaration's own name with that
/// name when there is no better target (and language servers do the same: sourcekit-lsp returns
/// the declaration's own location). Reselecting the name and recording a checkpoint for that is
/// a no-op navigation. The platform norm is IntelliJ's "Go to Declaration or Usages" (on a
/// declaration it shows usages) and VS Code's `gotoLocation.alternativeDefinitionCommand` (Find
/// References when the definition is the current location), so both delivery paths — ⌘-click in
/// `JumpToDefinitionController` and keyboard in `EditorIntelligenceController.navigate(kind:)` —
/// consult this one rule instead of duplicating it, and rerun navigation as `.references`.
enum NavigationSelfRedirect {
    /// Identifier bounds around `offset` (UTF-16 units), or nil when `offset` is not on an
    /// identifier. Same scan as the click controller, so both paths agree on the identifier;
    /// a leading digit disqualifies, as numbers are not identifiers.
    static func identifierRange(at offset: Int, in text: NSString) -> NSRange? {
        guard offset >= 0, offset < text.length, isIdentifierCharacter(text.character(at: offset)) else { return nil }
        var start = offset
        while start > 0, isIdentifierCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        if text.character(at: start) >= 48 && text.character(at: start) <= 57 { return nil }
        var end = offset + 1
        while end < text.length, isIdentifierCharacter(text.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The self location: `result` is one in-document `.source` location whose range lies within
    /// `identifier`. Anything else — another kind, several targets, a non-source target, a target
    /// in another document, a location outside the identifier — is not a self result.
    /// A single-element `.multiple` counts as one, the way both delivery paths already treat it.
    static func selfLocation(
        in result: NavigationResult, kind: NavigationKind,
        identifier: NSRange, documentURL: URL?
    ) -> Location? {
        guard kind == .definition, identifier.length > 0 else { return nil }
        let location: Location
        switch result {
        case .single(let candidate):
            location = candidate
        case .multiple(let candidates) where candidates.count == 1:
            location = candidates[0]
        case .multiple:
            return nil
        }
        guard location.target == .source else { return nil }
        // A provider answers the current document with `url` unset; anything set must match.
        if let url = location.url, url != documentURL { return nil }
        guard location.range.start.utf16Offset >= identifier.location,
              location.range.end.utf16Offset <= NSMaxRange(identifier) else { return nil }
        return location
    }

    private static func isIdentifierCharacter(_ unit: unichar) -> Bool {
        if unit == 95 || unit == 36 { return true }
        if unit >= 65 && unit <= 90 { return true }
        if unit >= 97 && unit <= 122 { return true }
        if unit >= 48 && unit <= 57 { return true }
        return unit > 127
    }
}
