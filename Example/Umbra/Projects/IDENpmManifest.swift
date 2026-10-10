import Foundation

/// One `scripts` entry, in the order it is written in package.json.
struct IDENpmScript: Equatable, Sendable {
    var name: String
    var command: String
}

/// One declared dependency. A name that appears in two sections is two entries.
struct IDENpmDependency: Equatable, Sendable {
    /// `dependencies`, `devDependencies`, `peerDependencies`, or `optionalDependencies`.
    var section: String
    var name: String
    var requirement: String
}

/// The root package.json: the package name, the scripts, and the declared dependency names.
/// Parsing does not install anything and does not read a lockfile. Key order is the file's order.
struct IDENpmManifest: Equatable, Sendable {
    var packageName: String
    var scripts: [IDENpmScript]
    var dependencies: [IDENpmDependency]

    var dependencyCount: Int { dependencies.count }

    /// Nil when `data` is not a JSON object. A valid `{}` is a package with the folder's name.
    static func parse(data: Data, folderName: String) -> IDENpmManifest? {
        let data = strippingBOM(data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = String(data: data, encoding: .utf8) else { return nil }
        let rawName = object["name"] as? String
        let packageName = (rawName?.isEmpty == false) ? rawName! : folderName
        var scanner = IDENpmJSONScanner(text)
        let scripts = scanner.stringMap(named: "scripts").map { IDENpmScript(name: $0.name, command: $0.value) }
        var dependencies: [IDENpmDependency] = []
        for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            for entry in scanner.stringMap(named: section) {
                dependencies.append(IDENpmDependency(section: section, name: entry.name, requirement: entry.value))
            }
        }
        return IDENpmManifest(packageName: packageName, scripts: scripts, dependencies: dependencies)
    }

    private static func strippingBOM(_ data: Data) -> Data {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return Data(data.dropFirst(3)) }
        return data
    }
}

/// Reads top-level string maps in source order. `JSONSerialization` does not keep key order.
/// A key that is present but is not an object contributes nothing. The first top-level occurrence wins.
private struct IDENpmJSONScanner {
    struct Entry {
        var name: String
        var value: String
    }

    private let text: String
    private var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    mutating func stringMap(named key: String) -> [Entry] {
        index = text.startIndex
        skipWhitespace()
        guard consume("{") else { return [] }
        while index < text.endIndex {
            skipWhitespace()
            if consume("}") { return [] }
            guard let found = parseString() else { return [] }
            skipWhitespace()
            guard consume(":") else { return [] }
            skipWhitespace()
            if found == key {
                guard peek() == "{" else { return [] }
                return parseStringObject()
            }
            guard skipValue() else { return [] }
            skipWhitespace()
            if consume(",") { continue }
            if consume("}") { return [] }
            return []
        }
        return []
    }

    private mutating func parseStringObject() -> [Entry] {
        guard consume("{") else { return [] }
        var entries: [Entry] = []
        while index < text.endIndex {
            skipWhitespace()
            if consume("}") { return entries }
            guard let name = parseString() else { return entries }
            skipWhitespace()
            guard consume(":") else { return entries }
            skipWhitespace()
            if peek() == "\"" {
                if let value = parseString() {
                    entries.append(Entry(name: name, value: value))
                }
            } else {
                guard skipValue() else { return entries }
            }
            skipWhitespace()
            if consume(",") { continue }
            if consume("}") { return entries }
            return entries
        }
        return entries
    }

    private mutating func parseString() -> String? {
        guard consume("\"") else { return nil }
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\"" { return result }
            if character != "\\" {
                result.append(character)
                continue
            }
            guard index < text.endIndex else { return nil }
            let escaped = text[index]
            index = text.index(after: index)
            switch escaped {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                guard let scalar = parseHexScalar() else { return nil }
                result.append(Character(scalar))
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func parseHexScalar() -> Unicode.Scalar? {
        var hex = ""
        for _ in 0..<4 {
            guard let character = peek(), character.isHexDigit else { return nil }
            hex.append(character)
            index = text.index(after: index)
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return Unicode.Scalar(value)
    }

    private mutating func skipValue() -> Bool {
        skipWhitespace()
        guard let character = peek() else { return false }
        if character == "\"" { return parseString() != nil }
        if character == "{" { return skipContainer(open: "{", close: "}") }
        if character == "[" { return skipContainer(open: "[", close: "]") }
        while let character = peek(), character != "," && character != "}" && character != "]" && !character.isWhitespace {
            index = text.index(after: index)
        }
        return true
    }

    private mutating func skipContainer(open: Character, close: Character) -> Bool {
        guard consume(open) else { return false }
        var depth = 1
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                guard parseString() != nil else { return false }
                continue
            }
            index = text.index(after: index)
            if character == open { depth += 1 }
            else if character == close {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }

    private mutating func skipWhitespace() {
        while let character = peek(), character.isWhitespace {
            index = text.index(after: index)
        }
    }

    private func peek() -> Character? {
        index < text.endIndex ? text[index] : nil
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard peek() == character else { return false }
        index = text.index(after: index)
        return true
    }
}
