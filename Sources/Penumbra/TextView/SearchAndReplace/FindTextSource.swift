import Foundation

/// Sendable document view for ``FindSearchEngine``. Does not require a full UTF-16 copy.
public protocol FindTextSource: Sendable {
    var utf16Length: Int { get }
    /// UTF-16 window. Implementations may return fewer units at EOF.
    func substring(utf16Offset: Int, length: Int) -> String
    /// Non-nil when the document is already a contiguous UTF-16 buffer (untitled / `set text`).
    /// File-backed sources return nil so callers cannot accidentally materialize.
    var contiguousNSString: NSString? { get }
}

extension FindTextSource {
    public var contiguousNSString: NSString? { nil }
}

/// Wraps a `String` for ``FindSearchEngine`` overloads. `String` itself does not conform, so
/// `in text: String` and `in source: any FindTextSource` do not compete in overload ranking.
struct StringFindTextSource: FindTextSource {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    var utf16Length: Int {
        (string as NSString).length
    }

    func substring(utf16Offset: Int, length: Int) -> String {
        let ns = string as NSString
        let location = max(0, utf16Offset)
        let take = max(0, min(length, ns.length - location))
        guard take > 0 else {
            return ""
        }
        return ns.substring(with: NSRange(location: location, length: take))
    }

    var contiguousNSString: NSString? {
        string as NSString
    }
}
