import Foundation

/// A JPMS module declaration (`module-info.java`): its name, what it requires and what it exports.
/// Only what visibility needs is kept (`opens`, `uses` and `provides` are ignored).
public struct JavaModuleDescriptor: Sendable, Equatable {
    public struct Requires: Sendable, Equatable {
        public let module: String
        public let isTransitive: Bool
        public let isStatic: Bool
    }

    public struct Exports: Sendable, Equatable {
        public let package: String
        /// Empty for an unqualified export; otherwise the only modules that may read the package.
        public let to: [String]
    }

    public let name: String
    public let isOpen: Bool
    public let requires: [Requires]
    public let exports: [Exports]

    public init(name: String, isOpen: Bool = false, requires: [Requires] = [], exports: [Exports] = []) {
        self.name = name
        self.isOpen = isOpen
        self.requires = requires
        self.exports = exports
    }

    /// Whether `package` is visible to `reader` (a module name; nil for "any module").
    public func exports(package: String, to reader: String?) -> Bool {
        exports.contains { export in
            export.package == package && (export.to.isEmpty || reader.map(export.to.contains) == true)
        }
    }

    /// Reads a `module-info.java`. Tolerant: comments and annotations are skipped, and a
    /// statement it does not understand is ignored. Nil when there is no `module` declaration.
    public static func parse(source: String) -> JavaModuleDescriptor? {
        let text = stripComments(source)
        guard let moduleRange = text.range(of: #"(?:\bopen\s+)?\bmodule\s+[A-Za-z_$][\w$.]*\s*\{"#, options: .regularExpression),
              let close = text.lastIndex(of: "}"), moduleRange.upperBound <= close else { return nil }
        let header = String(text[moduleRange])
        let isOpen = header.range(of: #"^\s*open\b"#, options: .regularExpression) != nil
        guard let nameRange = header.range(of: #"\bmodule\s+([A-Za-z_$][\w$.]*)"#, options: .regularExpression) else { return nil }
        let name = String(header[nameRange]).replacingOccurrences(of: #"^\s*module\s+"#, with: "", options: .regularExpression)
        var requires: [Requires] = []
        var exports: [Exports] = []
        let body = text[moduleRange.upperBound..<close]
        for statement in body.split(separator: ";") {
            let words = statement.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard let keyword = words.first else { continue }
            switch keyword {
            case "requires":
                var transitive = false
                var isStatic = false
                var rest = words.dropFirst()
                while let modifier = rest.first, modifier == "transitive" || modifier == "static" {
                    // `requires transitive;` would name a module `transitive`: only a modifier when a name follows.
                    guard rest.count > 1 else { break }
                    if modifier == "transitive" { transitive = true } else { isStatic = true }
                    rest = rest.dropFirst()
                }
                if let module = rest.first { requires.append(Requires(module: module, isTransitive: transitive, isStatic: isStatic)) }
            case "exports":
                guard words.count > 1 else { continue }
                let package = words[1]
                var targets: [String] = []
                if let to = words.firstIndex(of: "to") { targets = Array(words[(to + 1)...]) }
                exports.append(Exports(package: package, to: targets))
            default:
                continue
            }
        }
        return JavaModuleDescriptor(name: name, isOpen: isOpen, requires: requires, exports: exports)
    }

    private static func stripComments(_ source: String) -> String {
        var result = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        return result
    }
}
