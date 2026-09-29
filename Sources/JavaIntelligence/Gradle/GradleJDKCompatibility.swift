import Foundation

/// Which JDKs a Gradle version can run on. Gradle compiles build scripts with a bundled Groovy that
/// cannot read class files newer than the Java it was released for, so launching an older wrapper on
/// the newest installed JDK fails with `Unsupported class file major version N`.
public enum GradleJDKCompatibility {
    /// The newest Java feature version that a Gradle release runs on, by the first Gradle version
    /// that supports it (ascending). Versions past the last entry are treated as unbounded.
    private static let supportedJava: [(gradle: [Int], java: Int)] = [
        ([4, 7], 10), ([5, 0], 11), ([5, 4], 12), ([6, 0], 13), ([6, 3], 14), ([6, 7], 15),
        ([7, 0], 16), ([7, 3], 17), ([7, 5], 18), ([7, 6], 19), ([8, 3], 20), ([8, 5], 21),
        ([8, 8], 22), ([8, 10], 23), ([8, 14], 24), ([9, 1], 25), ([9, 4], 26)
    ]

    /// The newest Java feature version `gradleVersion` (`"8.5"`, `"7.6.4"`, `"8.10-rc-1"`) runs on,
    /// or `nil` when the version is unreadable or newer than this table knows.
    public static func maximumJavaVersion(forGradle gradleVersion: String) -> Int? {
        let numeric = gradleVersion.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let version = [parts[0], parts[1]]
        guard let index = supportedJava.lastIndex(where: { !version.lexicographicallyPrecedes($0.gradle) }) else {
            return 9 // Gradle before 4.7 predates Java 10.
        }
        return index == supportedJava.count - 1 ? nil : supportedJava[index].java
    }

    /// The Gradle version a project's wrapper pins, read from `distributionUrl` in
    /// `gradle/wrapper/gradle-wrapper.properties` (`…/gradle-8.5-bin.zip`). `nil` without a wrapper.
    public static func wrapperVersion(in projectRoot: URL) -> String? {
        let properties = projectRoot.appendingPathComponent("gradle/wrapper/gradle-wrapper.properties")
        guard let text = try? String(contentsOf: properties, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("distributionUrl") {
            guard let range = line.range(of: "gradle-") else { continue }
            let rest = line[range.upperBound...]
            return String(rest.prefix { $0.isNumber || $0 == "." })
        }
        return nil
    }

    /// The Java cap for a project's wrapper, or `nil` when there is none or it is unbounded.
    public static func maximumJavaVersion(forProject projectRoot: URL) -> Int? {
        wrapperVersion(in: projectRoot).flatMap(maximumJavaVersion(forGradle:))
    }
}
