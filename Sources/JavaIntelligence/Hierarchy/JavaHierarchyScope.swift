import EditorIntelligence
import Foundation

/// Which sources a hierarchy search looks at: all of them, production only, or tests only.
enum JavaHierarchyScope {
    /// Whether a file belongs to `scope`. A Gradle source set whose name has "test" in it is a
    /// test source; without a model, or for a file outside every source set, a `src/test` or
    /// `test/java` folder is. A class from a JAR or the JDK (no project file) is production.
    static func contains(_ file: URL?, scope: HierarchyScope, model: JavaGradleProjectModel?) -> Bool {
        guard scope != .all else { return true }
        guard let file else { return scope == .production }
        let isTest: Bool
        if let set = model?.sourceSet(containing: file) {
            isTest = set.sourceSet.name.lowercased().contains("test")
        } else {
            let path = file.standardizedFileURL.path
            isTest = path.contains("/src/test/") || path.contains("/test/java/")
        }
        return scope == .tests ? isTest : !isTest
    }

    static func contains(_ stub: JavaClassStub, scope: HierarchyScope, model: JavaGradleProjectModel?) -> Bool {
        guard case .source(let url, _) = stub.origin else { return scope != .tests }
        return contains(url, scope: scope, model: model)
    }
}
