import Foundation

/// Which paths under a project root should offer a Gradle reload. Matched against absolute FSEvents
/// paths. Generated output (`build/`) and the daemon cache (`.gradle/`) are skipped so a sync
/// doesn't immediately ask to sync again.
public enum GradleBuildFiles {
    public static func matches(path: String) -> Bool {
        if path.contains("/build/") || path.contains("/.gradle/") {
            return false
        }
        switch URL(fileURLWithPath: path).lastPathComponent {
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties":
            return true
        case "libs.versions.toml":
            return path.hasSuffix("/gradle/libs.versions.toml")
        case "gradle-wrapper.properties":
            return path.hasSuffix("/gradle/wrapper/gradle-wrapper.properties")
        default:
            return false
        }
    }
}
