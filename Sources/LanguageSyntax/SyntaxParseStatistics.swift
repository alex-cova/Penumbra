import os

/// How many tree-sitter parses `SyntaxParser` has made since the process started.
///
/// Observability for tests and benchmarks that hold a feature to "this many parses per edit": the
/// time a parse takes varies with the machine and the build, the number of them does not. A parse
/// is counted when it is requested, whether or not it produces a tree. Costs one uncontended lock
/// per parse, which a parse dwarfs.
public enum SyntaxParseStatistics {
    public struct Counts: Sendable, Equatable {
        /// Parses started from nothing (`SyntaxParser.parse(_:)`).
        public var full = 0
        /// Reparses against an edited tree (`SyntaxParser.parseIncremental`).
        public var incremental = 0

        public var total: Int { full + incremental }

        public static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(full: lhs.full - rhs.full, incremental: lhs.incremental - rhs.incremental)
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counts())

    public static var counts: Counts {
        state.withLock { $0 }
    }

    private static let observerState = OSAllocatedUnfairLock<(@Sendable (_ incremental: Bool) -> Void)?>(initialState: nil)

    /// Called on the parsing thread for every parse while set, so a benchmark can record who asked
    /// (`Thread.callStackSymbols`). nil in the app.
    @_spi(Benchmarks) public static func setObserver(_ observer: (@Sendable (_ incremental: Bool) -> Void)?) {
        observerState.withLock { $0 = observer }
    }

    static func noteFullParse() {
        state.withLock { $0.full += 1 }
        observerState.withLock { $0 }?(false)
    }

    static func noteIncrementalParse() {
        state.withLock { $0.incremental += 1 }
        observerState.withLock { $0 }?(true)
    }
}
