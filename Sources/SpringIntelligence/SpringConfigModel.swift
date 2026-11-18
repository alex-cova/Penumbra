import Foundation

public struct SpringEffectiveValue: Sendable {
    public struct Source: Sendable { public let file: SpringConfigFile; public let entry: SpringConfigEntry; public let profile: String? }
    public let winner: Source
    /// Values this one overrides under the analysis profiles, lowest precedence first.
    public let overridden: [Source]
    /// Values from profiles that are not active here, so they would apply under another selection.
    public let inactive: [Source]
    /// True when the active profiles were inferred (none chosen, none configured) rather than known.
    public let profilesAssumed: Bool
}

/// The configuration side of the Spring model: parsed `application*` files, merged metadata, and the
/// queries and diagnostics built on them. Immutable and cheap to copy; rebuilt only when a config file,
/// the metadata, or the Java model changes.
public struct SpringConfigModel: Sendable {
    public let files: [SpringConfigFile]
    public let metadata: SpringConfigMetadata
    public let prefixes: [SpringConfigurationPrefix]
    public let valueReferences: [SpringValueReference]
    /// Profiles used for effective values: the analysis selection, else `spring.profiles.active` from base config.
    public let activeProfiles: [String]
    public let profilesAssumed: Bool
    public let knownProfiles: Set<String>
    /// Folders `classpath:` imports resolve against.
    public let resourceRoots: [URL]
    private let byURL: [URL: SpringConfigFile]
    private let byUniformKey: [String: [(file: Int, entry: Int)]]

    init(files: [SpringConfigFile], metadata: SpringConfigMetadata, model: SpringModel, analysisProfiles: Set<String>?,
         resourceRoots: [URL]) {
        let sorted = files.sorted { $0.url.path < $1.url.path }
        self.files = sorted
        self.metadata = metadata
        prefixes = model.configurationPrefixes
        valueReferences = model.valueReferences
        self.resourceRoots = resourceRoots
        byURL = Dictionary(uniqueKeysWithValues: sorted.map { ($0.url, $0) })
        var index: [String: [(Int, Int)]] = [:]
        for (fi, f) in sorted.enumerated() {
            for (ei, e) in f.entries.enumerated() { index[SpringConfigMetadata.uniform(e.key), default: []].append((fi, ei)) }
        }
        byUniformKey = index
        var profiles = Set(model.declaredProfiles)
        for f in sorted { if let p = f.fileProfile { profiles.insert(p) }; profiles.formUnion(f.documentProfiles.values) }
        knownProfiles = profiles
        if let analysis = analysisProfiles {
            activeProfiles = analysis.sorted()
            profilesAssumed = false
        } else {
            var configured: [String] = []
            for f in sorted where f.fileProfile == nil {
                for e in f.entries where e.key == "spring.profiles.active" || e.key == "spring.profiles.include" {
                    configured += (e.value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("${") }
                }
            }
            activeProfiles = configured
            profilesAssumed = configured.isEmpty
        }
    }

    public static let empty = SpringConfigModel(files: [], metadata: .empty, model: .empty, analysisProfiles: nil, resourceRoots: [])

    public func file(at url: URL) -> SpringConfigFile? { byURL[url] }

    /// The entry whose key (or value) covers `byte` in `url`, and which part.
    public enum Hit: Sendable { case key(SpringConfigEntry, segment: Int), value(SpringConfigEntry) }
    public func hit(in url: URL, atByte byte: Int) -> (file: SpringConfigFile, hit: Hit)? {
        guard let f = byURL[url] else { return nil }
        for e in f.entries {
            if let i = e.segments.firstIndex(where: { $0.range.contains(byte) || $0.range.upperBound == byte }) { return (f, .key(e, segment: i)) }
            if let r = e.valueRange, r.contains(byte) || r.upperBound == byte { return (f, .value(e)) }
        }
        return nil
    }

    /// Every entry for a key, under relaxed binding (`app.maxSize` finds `app.max-size`).
    public func entries(forKey key: String) -> [(file: SpringConfigFile, entry: SpringConfigEntry)] {
        (byUniformKey[SpringConfigMetadata.uniform(key)] ?? []).map { (files[$0.file], files[$0.file].files(at: $0.entry)) }
    }

    /// Entries at or below `prefix` (for a `@ConfigurationProperties` prefix).
    public func entries(underPrefix prefix: String) -> [(file: SpringConfigFile, entry: SpringConfigEntry)] {
        let u = SpringConfigMetadata.uniform(prefix)
        var out: [(SpringConfigFile, SpringConfigEntry)] = []
        for f in files {
            for e in f.entries {
                let k = SpringConfigMetadata.uniform(e.key)
                if k == u || k.hasPrefix(u + ".") { out.append((f, e)) }
            }
        }
        return out
    }

    // MARK: Effective values (Spring Boot property-source order, restricted to application files)

    /// Which entry wins for `key`: base files, then profile files and activated YAML documents in the order the
    /// profiles are active, and within one level `.properties` over `.yml`. Environment variables, system
    /// properties and command-line arguments rank above every file and are never visible statically.
    public func effective(key: String) -> SpringEffectiveValue? {
        var active: [SpringEffectiveValue.Source] = [], inactive: [SpringEffectiveValue.Source] = []
        for (file, entry) in entries(forKey: key) {
            let profile = file.profile(of: entry)
            let src = SpringEffectiveValue.Source(file: file, entry: entry, profile: profile)
            if profile == nil || activeProfiles.contains(profile!) { active.append(src) } else { inactive.append(src) }
        }
        guard !active.isEmpty || !inactive.isEmpty else { return nil }
        func rank(_ s: SpringEffectiveValue.Source) -> (Int, Int, Int) {
            let profileRank = s.profile.flatMap { activeProfiles.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            return (profileRank, s.file.format == .properties ? 1 : 0, s.entry.document)
        }
        let ordered = active.sorted { rank($0) < rank($1) }
        guard let winner = ordered.last else {
            return SpringEffectiveValue(winner: inactive[0], overridden: [], inactive: Array(inactive.dropFirst()), profilesAssumed: profilesAssumed)
        }
        return SpringEffectiveValue(winner: winner, overridden: Array(ordered.dropLast()), inactive: inactive, profilesAssumed: profilesAssumed)
    }

    public func definesKey(_ key: String) -> Bool { byUniformKey[SpringConfigMetadata.uniform(key)] != nil }

    // MARK: Diagnostics

    public func diagnostics(for url: URL) -> [SpringDiagnostic] {
        guard let file = byURL[url] else { return [] }
        var out: [SpringDiagnostic] = []
        func at(_ e: SpringConfigEntry, value: Bool = false) -> SpringSourceLocation {
            SpringSourceLocation(url: url, byteRange: value ? (e.valueRange ?? e.keyRange) : e.keyRange)
        }

        // Duplicates inside one document of one file.
        var seen: [String: SpringConfigEntry] = [:]
        for e in file.entries {
            let k = "\(e.document)|" + SpringConfigMetadata.uniform(e.key)
            if let first = seen[k] {
                out.append(SpringDiagnostic(
                    severity: .warning, code: "spring.config.duplicate-key",
                    message: "Duplicate property '\(e.key)': also set on line \(first.line + 1); the later value wins", location: at(e), related: []))
            } else { seen[k] = e }
        }
        // `.properties` and `.yml` of the same name side by side: Boot loads both, `.properties` wins.
        if file.format == .yaml, let twin = files.first(where: { $0.format == .properties && $0.fileProfile == file.fileProfile && $0.url.deletingLastPathComponent() == url.deletingLastPathComponent() }) {
            let twinKeys = Set(twin.entries.map { SpringConfigMetadata.uniform($0.key) })
            for e in file.entries where twinKeys.contains(SpringConfigMetadata.uniform(e.key)) && file.profile(of: e) == file.fileProfile {
                out.append(SpringDiagnostic(
                    severity: .info, code: "spring.config.shadowed-by-properties",
                    message: "'\(e.key)' is also set in \(twin.url.lastPathComponent), which takes precedence over YAML", location: at(e), related: []))
            }
        }

        for e in file.entries {
            switch metadata.match(e.key) {
            case .exact(let p):
                if let d = p.deprecation {
                    let hint = d.replacement.map { " Use '\($0)' instead." } ?? ""
                    out.append(SpringDiagnostic(
                        severity: d.level == .error ? .error : .warning, code: "spring.config.deprecated",
                        message: "'\(p.name)' is deprecated.\(d.reason.map { " \($0)" } ?? "")\(hint)", location: at(e), related: []))
                }
                if !e.isOpaqueValue, let v = e.value, let problem = SpringConfigValueCheck.problem(value: v, type: p.type) {
                    out.append(SpringDiagnostic(severity: .error, code: "spring.config.invalid-value",
                                                message: "Invalid value for '\(p.name)': \(problem)", location: at(e, value: true), related: []))
                }
            case .unknown:
                let guess = suggestion(for: e.key)
                out.append(SpringDiagnostic(
                    severity: .warning, code: "spring.config.unknown-key",
                    message: "Unknown property '\(e.key)'" + (guess.map { ". Did you mean '\($0)'?" } ?? ""), location: at(e), related: []))
            default:
                break
            }
            if let v = e.value, !e.isOpaqueValue { out += placeholderDiagnostics(v, entry: e, url: url, valueStart: e.valueRange?.lowerBound ?? e.keyRange.lowerBound) }
            if e.key == "spring.config.import", let v = e.value { out += importDiagnostics(v, entry: e, file: file) }
        }
        return out
    }

    private func placeholderDiagnostics(_ value: String, entry e: SpringConfigEntry, url: URL, valueStart: Int) -> [SpringDiagnostic] {
        var out: [SpringDiagnostic] = []
        for p in SpringPlaceholder.scan(value) where !p.hasDefault && p.key.contains(".") {
            if definesKey(p.key) { continue }
            if case .exact = metadata.match(p.key) { continue }
            let lo = valueStart + String(value.utf16.prefix(p.keyRange.lowerBound))!.utf8.count
            let hi = valueStart + String(value.utf16.prefix(p.keyRange.upperBound))!.utf8.count
            // Not provably missing: the environment, system properties or the command line may define it.
            out.append(SpringDiagnostic(
                severity: .warning, code: "spring.config.unresolved-placeholder",
                message: "Placeholder '\(p.key)' is not defined in any application configuration file (it may come from the environment or command line)",
                location: SpringSourceLocation(url: url, byteRange: lo..<hi), related: []))
        }
        return out
    }

    private func importDiagnostics(_ value: String, entry e: SpringConfigEntry, file: SpringConfigFile) -> [SpringDiagnostic] {
        var out: [SpringDiagnostic] = []
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            guard !item.hasPrefix("optional:"), let url = resolveImport(item, from: file.url) else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                out.append(SpringDiagnostic(
                    severity: .warning, code: "spring.config.missing-import",
                    message: "Imported configuration '\(item)' was not found (prefix with optional: if it may be absent)",
                    location: SpringSourceLocation(url: file.url, byteRange: e.valueRange ?? e.keyRange), related: []))
            }
        }
        return out
    }

    /// `file:`/`classpath:`/plain relative locations of a `spring.config.import` item; `nil` for kinds that are not files
    /// (`configtree:`, `vault:`, `${…}`).
    public func resolveImport(_ raw: String, from base: URL) -> URL? {
        var item = raw
        if item.hasPrefix("optional:") { item = String(item.dropFirst("optional:".count)) }
        guard !item.contains("${"), !item.contains("://") || item.hasPrefix("file:") else { return nil }
        if item.hasPrefix("classpath:") {
            let rel = String(item.dropFirst("classpath:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for root in resourceRoots {
                let u = root.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: u.path) { return u.standardizedFileURL }
            }
            return resourceRoots.first.map { $0.appendingPathComponent(rel).standardizedFileURL }
        }
        if item.hasPrefix("file:") {
            let path = String(item.dropFirst("file:".count))
            if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
            return base.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        }
        if item.contains(":") { return nil }   // another scheme (configtree:, vault:, …)
        return base.deletingLastPathComponent().appendingPathComponent(item).standardizedFileURL
    }

    /// The closest known sibling of an unknown key (within two edits), for "Did you mean" and its quick fix.
    public func suggestion(for key: String) -> String? {
        let parent = key.split(separator: ".").dropLast().joined(separator: ".")
        let last = SpringConfigMetadata.uniform(String(key.split(separator: ".").last ?? ""))
        var best: (String, Int)?
        for name in metadata.sortedNames {
            let parts = name.split(separator: ".")
            guard parts.dropLast().joined(separator: ".") == SpringConfigMetadata.stripIndexes(parent) || SpringConfigMetadata.uniform(parts.dropLast().joined(separator: ".")) == SpringConfigMetadata.uniform(SpringConfigMetadata.stripIndexes(parent)) else { continue }
            let d = Self.editDistance(last, SpringConfigMetadata.uniform(String(parts.last ?? "")))
            if d <= 2, best == nil || d < best!.1 { best = (name, d) }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }
}

private extension SpringConfigFile {
    func files(at index: Int) -> SpringConfigEntry { entries[index] }
}

/// Spring Boot's own binding rules for scalar types, so a value the binder would reject is flagged and one it
/// accepts is not. Anything that mentions a placeholder, SpEL, or an unknown type is accepted.
enum SpringConfigValueCheck {
    static func problem(value raw: String, type: String?) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard let type, !v.isEmpty, !v.contains("${"), !v.contains("#{") else { return nil }
        switch type {
        case "java.lang.Integer", "int", "java.lang.Long", "long", "java.lang.Short", "short", "java.lang.Byte", "byte":
            return Int64(v) == nil && !(v.hasPrefix("0x") && Int64(v.dropFirst(2), radix: 16) != nil) ? "'\(v)' is not a whole number" : nil
        case "java.lang.Double", "double", "java.lang.Float", "float", "java.math.BigDecimal":
            return Double(v) == nil ? "'\(v)' is not a number" : nil
        case "java.lang.Boolean", "boolean":
            // StringToBooleanConverter
            return ["true", "on", "yes", "1", "false", "off", "no", "0"].contains(v.lowercased()) ? nil : "'\(v)' is not a boolean (true or false)"
        case "java.time.Duration":
            return durationOK(v) ? nil : "'\(v)' is not a duration (e.g. 30s, 5m, 100ms, PT30S)"
        case "org.springframework.util.unit.DataSize":
            return dataSizeOK(v) ? nil : "'\(v)' is not a data size (e.g. 10MB, 512KB)"
        default:
            return nil
        }
    }

    private static func durationOK(_ v: String) -> Bool {
        if v.uppercased().hasPrefix("P") || v.uppercased().hasPrefix("-P") || v.uppercased().hasPrefix("+P") { return true }
        let units = ["ns", "us", "ms", "s", "m", "h", "d"]
        let number = v.prefix { $0.isNumber || $0 == "-" || $0 == "+" }
        guard !number.isEmpty, Int64(number) != nil else { return false }
        let unit = v.dropFirst(number.count).lowercased()
        return unit.isEmpty || units.contains(unit)
    }

    private static func dataSizeOK(_ v: String) -> Bool {
        let number = v.prefix { $0.isNumber || $0 == "-" || $0 == "+" }
        guard !number.isEmpty, Int64(number) != nil else { return false }
        let unit = v.dropFirst(number.count).uppercased()
        return unit.isEmpty || ["B", "KB", "MB", "GB", "TB"].contains(unit)
    }
}
