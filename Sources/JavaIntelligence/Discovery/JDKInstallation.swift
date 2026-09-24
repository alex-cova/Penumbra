import Foundation

/// One discovered JDK installation, with the pieces the indexer reads from it. `ctSym`/`jmodsDir`
/// are mutually usable sources for the JDK's public API surface: `ct.sym` (present on every
/// mainline Temurin/Oracle/Zulu build) is preferred since it's much smaller and covers every
/// release back to 8; `jmods/` (not present on every distribution -- notably missing on some
/// Temurin builds) is the fallback.
public struct JDKInstallation: Hashable, Sendable {
    public let home: URL
    public let featureVersion: Int
    /// The exact version string from `release`'s `JAVA_VERSION`, e.g. "24.0.2".
    public let versionString: String
    public let vendor: String?

    public init(home: URL, featureVersion: Int, versionString: String, vendor: String?) {
        self.home = home
        self.featureVersion = featureVersion
        self.versionString = versionString
        self.vendor = vendor
    }

    public var ctSym: URL { home.appendingPathComponent("lib/ct.sym") }
    public var srcZip: URL { home.appendingPathComponent("lib/src.zip") }
    public var jmodsDir: URL { home.appendingPathComponent("jmods") }
    public var modulesImage: URL { home.appendingPathComponent("lib/modules") }

    /// `bin/javac` when this home ships a compiler (a JRE-only home doesn't), otherwise `nil`.
    public var javac: URL? {
        let url = home.appendingPathComponent("bin/javac")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public var hasCtSym: Bool { FileManager.default.fileExists(atPath: ctSym.path) }
    public var hasJmods: Bool { FileManager.default.fileExists(atPath: jmodsDir.path) }
    public var hasSrcZip: Bool { FileManager.default.fileExists(atPath: srcZip.path) }

    /// A stable identifier for cache/shard naming: the JDK's install path plus its exact version,
    /// so re-pointing `JAVA_HOME` at a different build under the same directory still invalidates.
    public var cacheKey: String {
        "\(home.path)@\(versionString)"
    }
}

/// Parses a JDK's `release` file (`JAVA_VERSION="24.0.2"`, `IMPLEMENTOR="Eclipse Adoptium"`, ...)
/// and derives the feature version (the leading version component: "24.0.2" -> 24, and the legacy
/// "1.8.0_392" -> 8).
enum ReleaseFileParser {
    static func parse(_ home: URL) -> JDKInstallation? {
        let releaseURL = home.appendingPathComponent("release")
        guard let contents = try? String(contentsOf: releaseURL, encoding: .utf8) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let versionString = fields["JAVA_VERSION"], let feature = featureVersion(from: versionString) else {
            return nil
        }
        let vendor = fields["IMPLEMENTOR"]
        return JDKInstallation(home: home, featureVersion: feature, versionString: versionString, vendor: vendor)
    }

    /// "24.0.2" -> 24, "17" -> 17, "11.0.20+8" -> 11, legacy "1.8.0_392" -> 8.
    static func featureVersion(from versionString: String) -> Int? {
        var s = Substring(versionString)
        if s.hasPrefix("1.") {
            s = s.dropFirst(2)
        }
        let digits = s.prefix { $0.isNumber }
        return Int(digits)
    }
}
