import Foundation

/// The call whose argument list holds the caret, read from the text. A call being typed
/// (`paint(.|`, `move(by: 1, |`) is rarely a call expression in the tree, and the bytes are
/// enough: the opening parenthesis, the commas at its own depth, the labels written so far.
struct SwiftCallSite {
    var callee: SwiftChain
    var calleeStart: Int
    var openParenthesis: Int
    /// Which argument the caret is in, from zero.
    var argumentIndex: Int
    /// The labels of the arguments before the caret (`"_"` for one without).
    var writtenLabels: [String]
    /// The caret argument's own label, when it is `name: …`.
    var currentLabel: String?

    static func find(parsed: SwiftParsed, at byte: Int) -> SwiftCallSite? {
        let bytes = parsed.text.utf8
        let caret = min(byte, bytes.count)
        var depth = 0
        var position = caret
        var open: Int?
        var scanned = 0
        while position > 0, scanned < 800 {
            position -= 1
            scanned += 1
            let c = bytes[position]
            if c == 0x29 || c == 0x5D || c == 0x7D {
                depth += 1
            } else if c == 0x28 || c == 0x5B || c == 0x7B {
                if depth == 0 {
                    guard c == 0x28 else { return nil }
                    open = position
                    break
                }
                depth -= 1
            } else if c == 0x3B {
                return nil
            }
        }
        guard let open else { return nil }
        var end = open
        while end > 0, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        guard end > 0 else { return nil }
        let (callee, start) = SwiftSite.chain(endingAt: end, parsed: parsed)
        if case .unknown = callee.base, callee.steps.isEmpty { return nil }

        let inside = String(decoding: bytes[(open + 1)..<caret], as: UTF8.self)
        let arguments = splitTopLevel(inside)
        let labels = arguments.map(label(of:))
        let current = arguments.last.flatMap { text -> String? in
            let label = label(of: text)
            return label == "_" ? nil : label
        }
        return SwiftCallSite(
            callee: callee, calleeStart: start, openParenthesis: open,
            argumentIndex: max(0, arguments.count - 1),
            writtenLabels: Array(labels.dropLast()), currentLabel: current
        )
    }

    /// The overloads whose parameters agree with the labels written before the caret, and have an
    /// argument for the caret's position (or are variadic).
    func compatible(_ overloads: [SwiftFileModel.Declaration]) -> [SwiftFileModel.Declaration] {
        overloads.filter { overload in
            let parameters = overload.parameters
            guard argumentIndex < parameters.count || parameters.last?.isVariadic == true else { return false }
            for (index, written) in writtenLabels.enumerated() where index < parameters.count {
                if (parameters[index].label ?? "_") != written { return false }
            }
            if let currentLabel, argumentIndex < parameters.count {
                return parameters[argumentIndex].label == currentLabel
            }
            return true
        }
    }

    private static func label(of argument: String) -> String {
        guard let colon = argument.firstIndex(of: ":") else { return "_" }
        let name = argument[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return "_" }
        return name
    }

    /// `a, b(c, d), e` split at the commas outside brackets and strings.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var previous: Character = " "
        for character in text {
            if inString {
                current.append(character)
                if character == "\"", previous != "\\" { inString = false }
                previous = character
                continue
            }
            switch character {
            case "\"":
                inString = true
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
            previous = character
        }
        parts.append(current)
        return parts
    }
}
