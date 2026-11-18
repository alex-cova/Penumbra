import Foundation

public struct SpringDeprecation: Hashable, Sendable {
    public enum Level: String, Sendable { case warning, error }
    public let level: Level
    public let reason: String?
    public let replacement: String?
}

public struct SpringPropertyMetadata: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// `META-INF/spring-configuration-metadata.json` (or the additional file) in a jar or output folder.
        case metadata(String)
        /// Derived from a project `@ConfigurationProperties` class.
        case source(SpringSourceLocation, className: String)
    }
    /// Canonical name: lower-case, dash-separated segments.
    public let name: String
    public let type: String?
    public let description: String?
    public let defaultValue: String?
    public let deprecation: SpringDeprecation?
    public let origin: Origin
}

public struct SpringValueHint: Hashable, Sendable {
    public let value: String
    public let description: String?
}

/// Spring Boot configuration metadata for one project: what keys exist, their types, defaults, hints
/// and deprecations. Names are indexed in Spring's "uniform" form (lower case, no `-`/`_`), which is
/// how relaxed binding compares keys, so `serverPort`, `SERVER_PORT` and `server-port` meet.
public struct SpringConfigMetadata: Sendable {
    public private(set) var properties: [String: SpringPropertyMetadata] = [:]   // by uniform name
    public private(set) var hints: [String: [SpringValueHint]] = [:]            // by uniform name
    private var groupPrefixes: Set<String> = []
    /// Canonical names in sorted order, for prefix completion.
    public private(set) var sortedNames: [String] = []
    private var sortedUniformNames: [String] = []

    public static let empty = SpringConfigMetadata()
    public var isEmpty: Bool { properties.isEmpty }

    /// Relaxed-binding comparison form of one key (`[0]` indexes are kept so list entries stay distinct).
    public static func uniform(_ key: String) -> String {
        var out = ""
        out.reserveCapacity(key.count)
        for ch in key where ch != "-" && ch != "_" { out.append(ch.lowercased().first ?? ch) }
        return out
    }

    /// `maxPoolSize` / `MAX_POOL_SIZE` → `max-pool-size`.
    public static func canonicalSegment(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch == "_" { out.append("-"); continue }
            if ch.isUppercase {
                if i > 0, !(out.last == "-") { out.append("-") }
                out.append(contentsOf: ch.lowercased())
            } else { out.append(ch) }
        }
        return out
    }

    public mutating func add(_ p: SpringPropertyMetadata) {
        let u = Self.uniform(p.name)
        if properties[u] == nil { properties[u] = p }   // first source wins (project before library)
        var prefix = ""
        for seg in p.name.split(separator: ".").dropLast() {
            prefix += (prefix.isEmpty ? "" : ".") + Self.uniform(String(seg))
            groupPrefixes.insert(prefix)
        }
    }

    public mutating func merge(_ other: SpringConfigMetadata) {
        for p in other.properties.values { add(p) }
        for (k, v) in other.hints where hints[k] == nil { hints[k] = v }
        finalize()
    }

    public mutating func finalize() {
        sortedNames = properties.values.map(\.name).sorted()
        sortedUniformNames = sortedNames.map(Self.uniform)
    }

    /// Parses `spring-configuration-metadata.json` content. Unknown fields are ignored; a malformed file yields nil.
    public static func parse(json: Data, origin: String) -> SpringConfigMetadata? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        var m = SpringConfigMetadata()
        for raw in (root["properties"] as? [[String: Any]]) ?? [] {
            guard let name = raw["name"] as? String else { continue }
            var dep: SpringDeprecation?
            if let d = raw["deprecation"] as? [String: Any] {
                dep = SpringDeprecation(level: (d["level"] as? String).flatMap(SpringDeprecation.Level.init) ?? .warning,
                                        reason: d["reason"] as? String, replacement: d["replacement"] as? String)
            } else if raw["deprecated"] as? Bool == true {
                dep = SpringDeprecation(level: .warning, reason: nil, replacement: nil)
            }
            m.add(SpringPropertyMetadata(
                name: name, type: raw["type"] as? String, description: raw["description"] as? String,
                defaultValue: raw["defaultValue"].flatMap(render), deprecation: dep, origin: .metadata(origin)))
        }
        for raw in (root["hints"] as? [[String: Any]]) ?? [] {
            guard let name = raw["name"] as? String else { continue }
            let values = ((raw["values"] as? [[String: Any]]) ?? []).compactMap { v -> SpringValueHint? in
                guard let value = v["value"].flatMap(render) else { return nil }
                return SpringValueHint(value: value, description: v["description"] as? String)
            }
            if !values.isEmpty { m.hints[uniform(name)] = values }
        }
        m.finalize()
        return m
    }

    private static func render(_ any: Any) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]: return a.compactMap(render).joined(separator: ",")
        default: return nil
        }
    }

    // MARK: Lookup

    public enum Match: Sendable {
        case exact(SpringPropertyMetadata)
        /// Under a property whose type holds arbitrary children (map, list, or a class the metadata does not expand).
        case opaque(parent: SpringPropertyMetadata)
        /// An intermediate path (`spring.datasource`) that has known properties below it.
        case group
        /// The parent path is a known group but nothing here is: the key is almost certainly a typo.
        case unknown
        /// Nothing in the metadata mentions the parent path (a third-party library without metadata).
        case foreign
    }

    public func match(_ key: String) -> Match {
        // `a.b[0].c` and `a.b.c` share one form; the index only matters for duplicates.
        let stripped = Self.stripIndexes(key)
        let u = Self.uniform(stripped)
        if let p = properties[u] { return .exact(p) }
        let segments = u.split(separator: ".").map(String.init)
        var prefix = ""
        for (i, seg) in segments.enumerated() {
            prefix += (prefix.isEmpty ? "" : ".") + seg
            if i < segments.count - 1, let p = properties[prefix], Self.holdsArbitraryChildren(p, hasHints: hints[prefix] != nil) {
                return .opaque(parent: p)
            }
            if i < segments.count - 1, let p = properties[prefix], Self.isLeaf(p) { return .unknown }
        }
        if groupPrefixes.contains(u) { return .group }
        let parent = segments.dropLast().joined(separator: ".")
        if segments.count > 1, groupPrefixes.contains(parent) { return .unknown }
        return .foreign
    }

    static func stripIndexes(_ key: String) -> String {
        var out = "", depth = 0
        for ch in key {
            if ch == "[" { depth += 1; continue }
            if ch == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    private static let simpleLeafPrefixes = ["java.lang.", "java.time.", "java.io.", "java.nio.", "java.net.", "java.math.", "org.springframework.util.unit."]

    static func isLeaf(_ p: SpringPropertyMetadata) -> Bool {
        guard let t = p.type else { return true }
        if ["int", "long", "boolean", "double", "float", "short", "byte", "char"].contains(t) { return true }
        return simpleLeafPrefixes.contains { t.hasPrefix($0) } && !t.hasPrefix("java.lang.Class")
    }

    static func holdsArbitraryChildren(_ p: SpringPropertyMetadata, hasHints: Bool) -> Bool {
        guard let t = p.type else { return false }
        if t.hasPrefix("java.util.") || t.contains("[]") || t.hasPrefix("org.springframework.core.io.") && t.contains("[]") { return true }
        if isLeaf(p) { return false }
        // A qualified non-JDK type with no value hints is either an enum or a bound class the metadata does
        // not expand; children under it cannot be judged.
        return !hasHints
    }

    /// Canonical property names that start with `prefix` (compared uniformly), at most `limit`.
    public func names(withUniformPrefix prefix: String, limit: Int = 400) -> [SpringPropertyMetadata] {
        var out: [SpringPropertyMetadata] = []
        for (i, uniformName) in sortedUniformNames.enumerated() {
            guard uniformName.hasPrefix(prefix) else { continue }
            if let p = properties[uniformName] { out.append(p) }
            if out.count >= limit { break }
            _ = i
        }
        return out
    }
}
