import Foundation

/// How Java adds, excludes and collapses imports. The defaults match IntelliJ's Java code style:
/// single-class imports, a package star at 5 classes, a static star at 3 names.
public struct JavaImportPolicy: Sendable, Equatable {
    public enum Paste: String, Sendable, Equatable {
        case always
        case never
    }

    /// Insert the one importable class for an unresolved simple name once the editor is idle.
    public var addUnambiguousImportsOnTheFly: Bool
    /// Whether pasting code with unresolved type names inserts their imports.
    public var insertImportsOnPaste: Paste
    /// Off writes `import pkg.*` as soon as a second class from that package is imported.
    public var useSingleClassImports: Bool
    /// Single-class imports from one package become `import pkg.*` at this count. `999` never collapses.
    public var classCountToUseStarImport: Int
    /// Static imports from one class become `import static Owner.*` at this count.
    public var staticCountToUseStarImport: Int
    /// Qualified class names (`java.awt.List`) and packages (`java.awt`). A package excludes classes
    /// whose package is exactly that name, not classes in a subpackage.
    public var excluded: [String]
    /// Classes whose static members completion may import (`java.util.Objects`). An entry with a
    /// leading `-` excludes one member (`-java.util.Objects.requireNonNull`).
    public var staticMemberClasses: [String]

    public init(
        addUnambiguousImportsOnTheFly: Bool = true,
        insertImportsOnPaste: Paste = .always,
        useSingleClassImports: Bool = true,
        classCountToUseStarImport: Int = 5,
        staticCountToUseStarImport: Int = 3,
        excluded: [String] = [],
        staticMemberClasses: [String] = []
    ) {
        self.addUnambiguousImportsOnTheFly = addUnambiguousImportsOnTheFly
        self.insertImportsOnPaste = insertImportsOnPaste
        self.useSingleClassImports = useSingleClassImports
        self.classCountToUseStarImport = classCountToUseStarImport
        self.staticCountToUseStarImport = staticCountToUseStarImport
        self.excluded = excluded
        self.staticMemberClasses = staticMemberClasses
    }

    public static let intellij = JavaImportPolicy()

    /// Names written in a settings field: commas or newlines, with surrounding whitespace removed.
    public static func names(in text: String) -> [String] {
        text.split { $0 == "," || $0 == "\n" || $0 == "\r" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A class another package may import: public, or package-private in `packageName`.
    public static func isImportable(_ stub: JavaClassStub, from packageName: String) -> Bool {
        stub.packageName == packageName || stub.modifiers.contains(.publicFlag)
    }

    public func excludesClass(_ stub: JavaClassStub) -> Bool {
        excluded.contains(stub.qualifiedName) || excluded.contains(stub.packageName)
    }

    public func excludesStaticMember(owner: String, name: String) -> Bool {
        staticMemberClasses.contains("-\(owner).\(name)")
    }

    /// Classes listed for static-member completion, in the order they were written.
    public var staticMemberOwners: [String] {
        var owners: [String] = []
        for entry in staticMemberClasses where !entry.hasPrefix("-") && !owners.contains(entry) {
            owners.append(entry)
        }
        return owners
    }

    /// How many single-class imports from one package collapse into a star.
    /// With single-class imports off, the second class from a package becomes a star.
    /// A non-positive count, and `999`, never collapse.
    var classStarThreshold: Int {
        guard useSingleClassImports else { return 2 }
        return Self.starThreshold(classCountToUseStarImport)
    }

    var staticStarThreshold: Int {
        Self.starThreshold(staticCountToUseStarImport)
    }

    private static func starThreshold(_ count: Int) -> Int {
        count > 0 && count < 999 ? count : .max
    }
}
