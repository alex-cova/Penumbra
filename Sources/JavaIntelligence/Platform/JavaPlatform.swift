import Foundation

/// What a build tool says about how one source set is compiled. Each value is only what the build
/// declared; nothing is inferred from another (a bytecode target is not an API release).
///
/// - `release`: `--release N` (Gradle `options.release`, Maven `<release>` /
///   `maven.compiler.release`, `<testRelease>` for tests). javac then compiles against release N's
///   exported API only, read from `ct.sym`.
/// - `toolchainVersion`: the JDK the build compiles with (Gradle `java.toolchain.languageVersion`,
///   Maven toolchains `jdk/version`). Without `--release`, that JDK's own platform is the API.
/// - `sourceCompatibility` / `targetCompatibility`: `-source` / `-target`. They limit syntax and
///   bytecode, never which platform classes resolve.
public struct JavaCompilerSettings: Codable, Sendable, Hashable {
    public var release: Int?
    public var toolchainVersion: Int?
    public var sourceCompatibility: Int?
    public var targetCompatibility: Int?

    public init(release: Int? = nil, toolchainVersion: Int? = nil, sourceCompatibility: Int? = nil, targetCompatibility: Int? = nil) {
        self.release = release
        self.toolchainVersion = toolchainVersion
        self.sourceCompatibility = sourceCompatibility
        self.targetCompatibility = targetCompatibility
    }
}

/// The platform API a source set's code is checked against, decided from ``JavaCompilerSettings``
/// the way javac and the build tools decide it.
public enum JavaPlatformAPI: Sendable, Hashable {
    /// `--release N`: exactly release N's API.
    case release(Int)
    /// Compiled by a JDK of feature version N without `--release`: that JDK's platform. When the
    /// JDK Umbra uses is another version, release N's signatures stand in for it.
    case toolchain(Int)
    /// Neither: the compiling JDK's own platform (Umbra's selected JDK). `sourceLevel` limits only
    /// syntax.
    case compilerJDK(sourceLevel: Int?)
    /// A model synced before compiler settings were recorded: only a language level that mixes
    /// toolchain and `sourceCompatibility` is known, so no API restriction is assumed.
    case legacy(languageLevel: Int?)

    public init(settings: JavaCompilerSettings?, legacyLanguageLevel: Int?) {
        guard let settings else {
            self = .legacy(languageLevel: legacyLanguageLevel)
            return
        }
        if let release = settings.release {
            self = .release(release)
        } else if let toolchain = settings.toolchainVersion {
            self = .toolchain(toolchain)
        } else {
            self = .compilerJDK(sourceLevel: settings.sourceCompatibility)
        }
    }

    /// The release whose platform classes resolve, or `nil` for the selected JDK's own platform.
    public var apiRelease: Int? {
        switch self {
        case .release(let release), .toolchain(let release): release
        case .compilerJDK, .legacy: nil
        }
    }
}

/// Names a platform inside ``JavaIndex/queryScope`` and ``JavaIndex/requiredShards``. A platform
/// source is published with its token as its `shardPath`, so the scope a module already passes to
/// every feature selects its platform with no other plumbing, and a release that is not indexed
/// yet is a missing required shard (the module's missing-class checks wait).
public enum JavaPlatformScope {
    public static let tokenPrefix = "java-platform:release="

    public static func token(release: Int) -> String { "\(tokenPrefix)\(release)" }

    /// The release a token names, or `nil` when `shardPath` is not a platform token.
    public static func release(ofToken shardPath: String) -> Int? {
        guard shardPath.hasPrefix(tokenPrefix) else { return nil }
        return Int(shardPath.dropFirst(tokenPrefix.count))
    }
}
