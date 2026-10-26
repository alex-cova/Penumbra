import Foundation

/// Inlay and code-vision switches per language. Java keeps the keys it already has
/// (`com.umbra.editor.javaInlayHints` and the rest). Another language reads
/// `com.umbra.editor.<language>.<name>`, and does not inherit Java's values.
enum IDELanguageEditorPreferences {
    static func inlayParameterNames(for language: String, defaults: UserDefaults = .standard) -> Bool {
        bool(language: language, name: "inlayHints", javaKey: "com.umbra.editor.javaInlayHints", defaults: defaults)
    }

    static func inlayVariableTypes(for language: String, defaults: UserDefaults = .standard) -> Bool {
        bool(language: language, name: "inlayVariableTypes", javaKey: "com.umbra.editor.javaInlayVariableTypes", defaults: defaults)
    }

    static func inlayLambdaTypes(for language: String, defaults: UserDefaults = .standard) -> Bool {
        bool(language: language, name: "inlayLambdaTypes", javaKey: "com.umbra.editor.javaInlayLambdaTypes", defaults: defaults)
    }

    static func codeVisionUsages(for language: String, defaults: UserDefaults = .standard) -> Bool {
        bool(language: language, name: "codeVisionUsages", javaKey: "com.umbra.editor.javaCodeVisionUsages", defaults: defaults)
    }

    static func codeVisionImplementations(for language: String, defaults: UserDefaults = .standard) -> Bool {
        bool(language: language, name: "codeVisionImplementations", javaKey: "com.umbra.editor.javaCodeVisionImplementations", defaults: defaults)
    }

    private static func bool(language: String, name: String, javaKey: String, defaults: UserDefaults) -> Bool {
        if language == "java" { return defaults.bool(forKey: javaKey) }
        return defaults.bool(forKey: "com.umbra.editor.\(language).\(name)")
    }
}
