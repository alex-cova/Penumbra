import Foundation

/// Which section of the New Project sheet a template sits in.
enum IDEProjectFamily: String, CaseIterable, Sendable {
    case swift
    case java

    var title: String {
        switch self {
        case .swift: "Swift"
        case .java: "Java"
        }
    }
}

/// The inputs a template reads, so the sheet shows only the fields that matter for it.
enum IDENewProjectField: Hashable, Sendable {
    case organizationIdentifier
    case minimumMacOS
}

/// What the user typed into the wizard.
struct IDENewProjectOptions: Equatable, Sendable {
    var name: String
    var organizationIdentifier: String = "com.example"
    var parentDirectory: URL
    var minimumMacOS: String = "15.0"
    var swiftToolsVersion: String = "6.2"

    /// The folder the project is created in.
    var rootURL: URL {
        parentDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// `name` as a C99 identifier: letters, digits and `_`, never starting with a digit. Used for
    /// module, target and product names.
    var productName: String {
        var result = ""
        for scalar in name.unicodeScalars {
            let isWord = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            result.unicodeScalars.append(isWord ? scalar : "_")
        }
        if result.isEmpty { return "App" }
        if let first = result.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            result = "_" + result
        }
        return result
    }

    /// `<organization>.<name>` with the characters a bundle identifier does not allow turned into `-`.
    var bundleIdentifier: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        var suffix = ""
        for scalar in name.unicodeScalars {
            suffix.unicodeScalars.append(scalar.isASCII && allowed.contains(scalar) ? scalar : "-")
        }
        let prefix = organizationIdentifier.trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? suffix : prefix + "." + suffix
    }

    /// The major.minor.patch of `minimumMacOS`, for `.macOS(.v15)`-style platform entries.
    var minimumMacOSMajor: Int {
        Int(minimumMacOS.split(separator: ".").first ?? "") ?? 15
    }
}

/// One file the wizard will write, relative to the new project's root.
struct IDEGeneratedFile: Equatable, Sendable {
    var path: String
    var data: Data

    init(path: String, data: Data) {
        self.path = path
        self.data = data
    }

    init(path: String, text: String) {
        self.init(path: path, data: Data(text.utf8))
    }
}

/// A kind of project the wizard can create. Pure: it produces files and touches no disk, so the
/// sheet can preview it and tests can read what it generates. Gradle templates conform to this too.
protocol IDEProjectTemplate: Sendable {
    var id: String { get }
    var family: IDEProjectFamily { get }
    var title: String { get }
    var summary: String { get }
    var systemImage: String { get }
    var fields: Set<IDENewProjectField> { get }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile]
    /// The file to open once the new project is the window's folder, relative to its root.
    func primaryFile(for options: IDENewProjectOptions) -> String?
}

enum IDEProjectTemplates {
    static let all: [any IDEProjectTemplate] =
        IDEXcodeProjectTemplates.all + IDESwiftPackageTemplates.all

    static func template(id: String) -> (any IDEProjectTemplate)? {
        all.first { $0.id == id }
    }

    /// Templates of one family, in display order.
    static func templates(in family: IDEProjectFamily) -> [any IDEProjectTemplate] {
        all.filter { $0.family == family }
    }

    /// Families that have at least one template, so the sheet never shows an empty section.
    static var families: [IDEProjectFamily] {
        IDEProjectFamily.allCases.filter { family in all.contains { $0.family == family } }
    }
}

/// Why the wizard's Create button is disabled.
enum IDENewProjectIssue: Equatable, Sendable {
    case emptyName
    case invalidName(String)
    case invalidOrganizationIdentifier
    case noLocation
    case alreadyExists(URL)

    var message: String {
        switch self {
        case .emptyName:
            "Enter a project name."
        case .invalidName(let reason):
            reason
        case .invalidOrganizationIdentifier:
            "The organization identifier must look like com.example."
        case .noLocation:
            "Choose where to create the project."
        case .alreadyExists(let url):
            "“\(url.lastPathComponent)” already exists in this location."
        }
    }
}

enum IDENewProjectValidator {
    /// Everything wrong with `options` for `template`, empty when the project can be created.
    static func issues(
        for options: IDENewProjectOptions,
        template: any IDEProjectTemplate,
        fileManager: FileManager = .default
    ) -> [IDENewProjectIssue] {
        var issues: [IDENewProjectIssue] = []
        let name = options.name
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.emptyName)
        } else if name.contains("/") || name.contains(":") {
            issues.append(.invalidName("The name can't contain “/” or “:”."))
        } else if name.hasPrefix(".") {
            issues.append(.invalidName("The name can't start with a dot."))
        } else if name != name.trimmingCharacters(in: .whitespaces) {
            issues.append(.invalidName("The name can't start or end with a space."))
        }
        if template.fields.contains(.organizationIdentifier), !isReverseDNS(options.organizationIdentifier) {
            issues.append(.invalidOrganizationIdentifier)
        }
        if options.parentDirectory.path.isEmpty || options.parentDirectory.path == "/" {
            issues.append(.noLocation)
        } else if issues.isEmpty, fileManager.fileExists(atPath: options.rootURL.path) {
            issues.append(.alreadyExists(options.rootURL))
        }
        return issues
    }

    /// `com.example`: two or more dot-separated labels of letters, digits and `-`.
    static func isReverseDNS(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
