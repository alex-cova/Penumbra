import AgentKit
import Foundation

/// Reads a tool call that MLX's parser refused, when the slip is a common one and the result is
/// still unambiguous. Small models often double the outer braces (`{{"name": …}}`, copied from a
/// template that escapes them) or wrap the call in a code fence. Nothing is guessed: the text must
/// parse as a JSON object, name a tool the request declared, and carry its arguments as an object.
enum MLXToolCallRecovery {
    struct Call: Equatable {
        let name: String
        /// Key-sorted JSON, as the loop stores arguments.
        let arguments: String
    }

    static func recover(_ raw: String, knownTools: Set<String>) -> Call? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<tool_call>", "</tool_call>", "```json", "```"] { text = text.replacingOccurrences(of: tag, with: "") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates = [text]
        var peeled = text
        // Up to two extra layers of braces: `{{ … }}` and `{{{ … }}}`.
        for _ in 0..<2 where peeled.hasPrefix("{{") && peeled.hasSuffix("}}") {
            peeled = String(peeled.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(peeled)
        }
        for candidate in candidates {
            guard let json = try? AgentKit.JSONValue(parsing: candidate), case .object(let object) = json,
                  let name = object["name"]?.stringValue, knownTools.contains(name)
            else { continue }
            let arguments = object["arguments"] ?? object["parameters"] ?? .object([:])
            guard case .object = arguments, let serialized = try? arguments.serialized() else { continue }
            return Call(name: name, arguments: serialized)
        }
        return nil
    }
}
