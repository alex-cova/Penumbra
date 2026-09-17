import Foundation
import TextFormation
import TextStory

/// Applies TextFormation filters for tab expansion, bracket pairing, and whitespace cleanup.
@MainActor
public final class TextFormationController {
    private let compositeFilter: CompositeFilter

    public init(tabWidth: Int = 4) {
        let tabFilter = LineLeadingWhitespaceFilter(string: String(repeating: " ", count: tabWidth))
        let pairs: [Filter] = [
            StandardOpenPairFilter(open: "(", close: ")"),
            StandardOpenPairFilter(open: "[", close: "]"),
            StandardOpenPairFilter(open: "{", close: "}"),
            StandardOpenPairFilter(open: "\"", close: "\""),
            StandardOpenPairFilter(open: "'", close: "'")
        ]
        compositeFilter = CompositeFilter(filters: [tabFilter] + pairs)
    }

    /// Process a text mutation through TextFormation filters.
    ///
    /// Returns the replacement string to use, or `nil` when the filters did not modify the mutation.
    public func processedReplacement(
        in string: String,
        selectedRange: NSRange,
        replacementText: String
    ) -> String? {
        let storage = StringTextStorage(string: string)
        let interface = TextInterfaceAdapter(
            getSelection: { selectedRange },
            setSelection: { _ in },
            storage: storage
        )
        let mutation = TextMutation(
            string: replacementText,
            range: selectedRange,
            limit: string.utf16.count
        )
        let action = compositeFilter.processMutation(mutation, in: interface)
        switch action {
        case .discard:
            return nil
        case .none, .stop:
            if storage.string != string {
                return storage.replacementText(for: selectedRange, original: string)
            }
            return nil
        }
    }
}

private final class StringTextStorage: TextStoring {
    private(set) var backing: String

    init(string: String) {
        self.backing = string
    }

    var length: Int {
        backing.utf16.count
    }

    func substring(from range: NSRange) -> String? {
        guard let textRange = Range(range, in: backing) else {
            return nil
        }
        return String(backing[textRange])
    }

    func applyMutation(_ mutation: TextMutation) {
        guard let range = Range(mutation.range, in: backing) else {
            return
        }
        backing.replaceSubrange(range, with: mutation.string)
    }

    var string: String { backing }

    func replacementText(for range: NSRange, original: String) -> String? {
        guard string != original, let textRange = Range(range, in: original) else {
            return nil
        }
        let prefix = original[..<textRange.lowerBound]
        let suffix = original[textRange.upperBound...]
        let inserted = string.dropFirst(prefix.count).dropLast(suffix.count)
        return String(inserted)
    }
}
