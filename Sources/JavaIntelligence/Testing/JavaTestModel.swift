import Foundation

/// A JUnit generation. JUnit 3 and TestNG are out of scope.
public enum JavaTestFramework: String, Hashable, Sendable, Codable, CaseIterable {
    case junit4
    case junit5

    /// The frameworks whose jars appear (by file name) on a classpath: `junit-jupiter*` (JUnit 5)
    /// or `junit-4.x.jar` / `junit.jar` (JUnit 4).
    public static func detect(classpathJars: [URL]) -> Set<JavaTestFramework> {
        var result = Set<JavaTestFramework>()
        for jar in classpathJars {
            let name = jar.lastPathComponent.lowercased()
            guard name.hasSuffix(".jar") else { continue }
            if name.hasPrefix("junit-jupiter") {
                result.insert(.junit5)
            } else if name == "junit.jar" || name.hasPrefix("junit-4") {
                result.insert(.junit4)
            }
        }
        return result
    }

    public static func detect(in sourceSet: JavaGradleProjectModel.SourceSet) -> Set<JavaTestFramework> {
        detect(classpathJars: sourceSet.compileClasspathJars)
    }
}

/// What a test method is, by its JUnit annotation.
public enum JavaTestMethodKind: String, Hashable, Sendable, Codable {
    case test
    case parameterized
    case repeated
    case factory
    case template
}

public struct JavaTestMethod: Hashable, Sendable {
    public let name: String
    /// UTF-8 byte range of the method's name identifier in the file (for a gutter marker's line).
    public let nameRange: Range<Int>
    public let kind: JavaTestMethodKind
    public let displayName: String
    public let isDisabled: Bool
    public let framework: JavaTestFramework
    /// Simple name of the class that declares the method when it is inherited from an abstract
    /// base class in the same file; `nil` for a method declared by the class itself.
    public let inheritedFrom: String?

    public init(
        name: String, nameRange: Range<Int>, kind: JavaTestMethodKind, displayName: String,
        isDisabled: Bool, framework: JavaTestFramework, inheritedFrom: String? = nil
    ) {
        self.name = name
        self.nameRange = nameRange
        self.kind = kind
        self.displayName = displayName
        self.isDisabled = isDisabled
        self.framework = framework
        self.inheritedFrom = inheritedFrom
    }
}

public struct JavaTestClass: Hashable, Sendable {
    public let simpleName: String
    /// `pkg.Outer.Inner`.
    public let qualifiedName: String
    /// `pkg.Outer$Inner`, as the JVM and Gradle's `--tests` filter know it.
    public let binaryName: String
    public let nameRange: Range<Int>
    public let displayName: String
    public let isNested: Bool
    public let isAbstract: Bool
    public let isDisabled: Bool
    public let framework: JavaTestFramework
    /// The text of a JUnit 4 `@RunWith(...)` argument, e.g. `Parameterized.class`.
    public let runner: String?
    public let methods: [JavaTestMethod]

    public init(
        simpleName: String, qualifiedName: String, binaryName: String, nameRange: Range<Int>,
        displayName: String, isNested: Bool, isAbstract: Bool, isDisabled: Bool,
        framework: JavaTestFramework, runner: String? = nil, methods: [JavaTestMethod]
    ) {
        self.simpleName = simpleName
        self.qualifiedName = qualifiedName
        self.binaryName = binaryName
        self.nameRange = nameRange
        self.displayName = displayName
        self.isNested = isNested
        self.isAbstract = isAbstract
        self.isDisabled = isDisabled
        self.framework = framework
        self.runner = runner
        self.methods = methods
    }
}

/// A discovered class with the file it lives in.
public struct JavaTestClassEntry: Hashable, Sendable {
    public let fileURL: URL
    public let testClass: JavaTestClass
}

public struct JavaTestSourceSetNode: Hashable, Sendable {
    public let name: String
    public let frameworks: Set<JavaTestFramework>
    /// Concrete (non-abstract) test classes, sorted by binary name.
    public let classes: [JavaTestClassEntry]
}

public struct JavaTestSubprojectNode: Hashable, Sendable {
    /// Gradle project path, e.g. `:app`.
    public let path: String
    public let directory: URL
    public let sourceSets: [JavaTestSourceSetNode]
}

/// Subproject -> source set -> class -> method.
public struct JavaTestTree: Hashable, Sendable {
    public let subprojects: [JavaTestSubprojectNode]

    public static let empty = JavaTestTree(subprojects: [])

    public var isEmpty: Bool { subprojects.allSatisfy { $0.sourceSets.allSatisfy { $0.classes.isEmpty } } }

    public var allClasses: [JavaTestClassEntry] {
        subprojects.flatMap { $0.sourceSets.flatMap(\.classes) }
    }
}

/// A test source set together with the subproject that owns it.
public struct JavaTestSourceSetRef: Sendable {
    public let subprojectPath: String
    public let subprojectDirectory: URL
    public let sourceSet: JavaGradleProjectModel.SourceSet
}

extension JavaGradleProjectModel.Subproject {
    /// Source sets whose name contains "test" (case-insensitive) or whose compile classpath has a
    /// JUnit jar. A superset of the `test` set that ``testSourceDirs`` reads.
    public var testSourceSets: [JavaGradleProjectModel.SourceSet] {
        sourceSets.filter { set in
            set.name.lowercased().contains("test") || !JavaTestFramework.detect(in: set).isEmpty
        }
    }
}

extension JavaGradleProjectModel {
    public var testSourceSetRefs: [JavaTestSourceSetRef] {
        subprojects.flatMap { sub in
            sub.testSourceSets.map {
                JavaTestSourceSetRef(subprojectPath: sub.path, subprojectDirectory: sub.directory, sourceSet: $0)
            }
        }
    }
}
