import Foundation
import SwiftUI

/// Type-select through a focused list: letters accumulate for a second, then the next one starts
/// a new query. A lengthening prefix stays on the current row when it still matches; repeating
/// the same letter cycles rows that start with it.
enum IDEListTypeahead {
    static let timeout: TimeInterval = 1

    /// Letters, digits, `.`, `_` and `-` with no Command, Option or Control.
    static func character(from press: KeyPress) -> Character? {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        guard press.characters.count == 1, let character = press.characters.first else { return nil }
        guard character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" else {
            return nil
        }
        return character
    }

    static func match<Item: Equatable>(
        query: String,
        in items: [Item],
        selected: Item?,
        title: (Item) -> String
    ) -> Item? {
        guard !items.isEmpty, !query.isEmpty else { return nil }
        let needle = query.lowercased()
        let cycling = Set(needle).count == 1
        let start: Int
        if let selected, let index = items.firstIndex(of: selected) {
            start = cycling ? (index + 1) % items.count : index
        } else {
            start = 0
        }
        for offset in 0..<items.count {
            let item = items[(start + offset) % items.count]
            if matches(title(item), needle: needle, cycling: cycling) {
                return item
            }
        }
        return nil
    }

    private static func matches(_ title: String, needle: String, cycling: Bool) -> Bool {
        let haystack = title.lowercased()
        if cycling, let character = needle.first {
            return haystack.first == character
        }
        return haystack.hasPrefix(needle)
    }
}

/// Accumulates type-select characters until ``IDEListTypeahead/timeout`` of idle.
struct IDETypeaheadBuffer: Equatable {
    private(set) var query = ""
    private var lastTyped = Date.distantPast

    mutating func typed(_ character: Character, now: Date = Date()) -> String {
        if now.timeIntervalSince(lastTyped) >= IDEListTypeahead.timeout {
            query = ""
        }
        query.append(character)
        lastTyped = now
        return query
    }

    mutating func reset() {
        query = ""
        lastTyped = .distantPast
    }
}
