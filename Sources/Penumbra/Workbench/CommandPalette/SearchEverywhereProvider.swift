import Foundation

/// A source of ``PaletteItem``s for "Search Everywhere". Built-in providers cover commands,
/// files, symbols and text actions; host apps add their own (settings, run configurations,
/// documentation…) by conforming and registering with ``SearchEverywhereEngine``.
public protocol SearchEverywhereProvider: AnyObject, Sendable {
    /// Heading the provider's rows are grouped under.
    var sectionTitle: String { get }
    /// Lower sorts earlier when sections are concatenated.
    var sectionOrder: Int { get }
    /// Items matching `query` (already trimmed). Called on every keystroke — keep it cheap or
    /// honour `Task.isCancelled`. An empty query should return a small default set (or none).
    func items(matching query: String, limit: Int) async -> [PaletteItem]
}

public extension SearchEverywhereProvider {
    var sectionOrder: Int { 100 }
}
