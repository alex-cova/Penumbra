import Foundation

/// Navigation provider that returns the symbols enclosing the current cursor position as a breadcrumb trail.
public actor BreadcrumbProvider: NavigationProvider {
    public let name = "Breadcrumb"
    private let index: SymbolIndex

    public init(index: SymbolIndex) {
        self.index = index
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        let cursorOffset = context.cursor.position.utf16Offset
        let symbols = await index.symbols(in: context.document.id)
        let locations = Self.breadcrumbLocations(from: symbols, cursorOffset: cursorOffset)
        guard !locations.isEmpty else { return nil }
        return .multiple(locations)
    }

    /// Symbols that enclose `cursorOffset`, outermost first, as breadcrumb `Location`s.
    ///
    /// When any symbol carries a `containerRange` (a real declaration extent), only those are
    /// considered and nesting is by containment of that range — so a cursor in a function body
    /// resolves to `Type › function`. Without container ranges this falls back to symbols whose
    /// name range actually spans the cursor.
    ///
    /// Indexed words and the file name are stored with an empty range at offset 0 (they are
    /// completion tokens, not scopes). A caret there — Select All leaves the caret at the start
    /// — must not turn every word in the file into a crumb. An empty range encloses nothing, and
    /// two symbols that merely overlap the caret collapse to the innermost chain.
    public static func breadcrumbLocations(from symbols: [Symbol], cursorOffset: Int) -> [Location] {
        let declarations = symbols.filter { $0.containerRange != nil && span(of: $0) > 0 }
        let candidates = declarations.isEmpty ? symbols.filter(isStructuralName) : declarations
        let enclosing = candidates.filter { contains($0, cursorOffset: cursorOffset) }
        return nestedChain(enclosing).map { symbol in
            Location(
                documentID: symbol.documentID,
                url: nil,
                range: symbol.range,
                displayName: symbol.name
            )
        }
    }

    /// Words and the file name are not scopes. A name range of zero length is not either.
    private static func isStructuralName(_ symbol: Symbol) -> Bool {
        switch symbol.kind {
        case .word, .fileName:
            return false
        default:
            return span(of: symbol) > 0
        }
    }

    private static func contains(_ symbol: Symbol, cursorOffset: Int) -> Bool {
        let bounds = bounds(of: symbol)
        guard bounds.end > bounds.start else { return false }
        return bounds.start <= cursorOffset && cursorOffset <= bounds.end
    }

    /// Outermost first. Each step is the smallest remaining symbol that strictly contains the
    /// one just chosen, so siblings that all happen to cover the caret become a single crumb.
    private static func nestedChain(_ enclosing: [Symbol]) -> [Symbol] {
        var remaining = enclosing
        var innermostFirst: [Symbol] = []
        while innermostFirst.count < BreadcrumbBarModel.maximumSegments, let inner = smallest(in: remaining) {
            innermostFirst.append(inner)
            remaining = remaining.filter { strictlyContains($0, inner) }
        }
        return innermostFirst.reversed()
    }

    private static func smallest(in symbols: [Symbol]) -> Symbol? {
        symbols.min { lhs, rhs in
            let left = span(of: lhs)
            let right = span(of: rhs)
            if left != right { return left < right }
            return bounds(of: lhs).start > bounds(of: rhs).start
        }
    }

    private static func strictlyContains(_ outer: Symbol, _ inner: Symbol) -> Bool {
        let outside = bounds(of: outer)
        let inside = bounds(of: inner)
        return outside.start <= inside.start && inside.end <= outside.end && span(of: outer) > span(of: inner)
    }

    private static func bounds(of symbol: Symbol) -> (start: Int, end: Int) {
        let range = symbol.enclosingRange
        return (
            min(range.start.utf16Offset, range.end.utf16Offset),
            max(range.start.utf16Offset, range.end.utf16Offset)
        )
    }

    private static func span(of symbol: Symbol) -> Int {
        let bounds = bounds(of: symbol)
        return bounds.end - bounds.start
    }
}
