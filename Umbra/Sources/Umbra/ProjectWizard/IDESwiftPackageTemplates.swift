import Foundation

/// SwiftPM templates: a `Package.swift` plus sources and a Swift Testing target. Umbra's
/// `IDESwiftPMProjectSystem` builds and runs what these write.
enum IDESwiftPackageTemplates {
    static let all: [any IDEProjectTemplate] = [
        IDESwiftPackageTemplate(kind: .executable),
        IDESwiftPackageTemplate(kind: .library),
    ]
}

struct IDESwiftPackageTemplate: IDEProjectTemplate {
    enum Kind: Sendable {
        case executable
        case library
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .executable: "swift.package.executable"
        case .library: "swift.package.library"
        }
    }

    var family: IDEProjectFamily { .swift }

    var title: String {
        switch kind {
        case .executable: "Executable Package"
        case .library: "Library Package"
        }
    }

    var summary: String {
        switch kind {
        case .executable: "A Swift package with a command-line executable and a test target."
        case .library: "A Swift package that vends a library, with a test target."
        }
    }

    var systemImage: String {
        switch kind {
        case .executable: "terminal"
        case .library: "shippingbox"
        }
    }

    var fields: Set<IDENewProjectField> { [.minimumMacOS] }

    func primaryFile(for options: IDENewProjectOptions) -> String? {
        switch kind {
        case .executable: "Sources/\(options.productName)/main.swift"
        case .library: "Sources/\(options.productName)/\(options.productName).swift"
        }
    }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
        let product = options.productName
        var files = [
            IDEGeneratedFile(path: "Package.swift", text: manifest(options)),
            IDEGeneratedFile(path: ".gitignore", text: Self.gitignore),
            IDEGeneratedFile(path: "Tests/\(product)Tests/\(product)Tests.swift", text: tests(product)),
        ]
        switch kind {
        case .executable:
            files.append(IDEGeneratedFile(
                path: "Sources/\(product)/main.swift",
                text: "print(\"Hello, world!\")\n"
            ))
        case .library:
            files.append(IDEGeneratedFile(
                path: "Sources/\(product)/\(product).swift",
                text: """
                public struct \(product) {
                    public init() {}

                    public func greeting() -> String {
                        "Hello, world!"
                    }
                }

                """
            ))
        }
        return files
    }

    private func manifest(_ options: IDENewProjectOptions) -> String {
        let product = options.productName
        let platform = ".macOS(.v\(options.minimumMacOSMajor))"
        switch kind {
        case .executable:
            // An executable target can't be imported by tests, so the test target covers the
            // executable's module only when it is a library; keep the target testable-free.
            return """
            // swift-tools-version: \(options.swiftToolsVersion)
            import PackageDescription

            let package = Package(
                name: "\(product)",
                platforms: [\(platform)],
                targets: [
                    .executableTarget(name: "\(product)"),
                    .testTarget(name: "\(product)Tests", dependencies: ["\(product)"]),
                ]
            )

            """
        case .library:
            return """
            // swift-tools-version: \(options.swiftToolsVersion)
            import PackageDescription

            let package = Package(
                name: "\(product)",
                platforms: [\(platform)],
                products: [
                    .library(name: "\(product)", targets: ["\(product)"]),
                ],
                targets: [
                    .target(name: "\(product)"),
                    .testTarget(name: "\(product)Tests", dependencies: ["\(product)"]),
                ]
            )

            """
        }
    }

    private func tests(_ product: String) -> String {
        switch kind {
        case .executable:
            return """
            import Testing

            @Suite struct \(product)Tests {
                @Test func arithmetic() {
                    #expect(1 + 1 == 2)
                }
            }

            """
        case .library:
            return """
            import Testing
            @testable import \(product)

            @Suite struct \(product)Tests {
                @Test func greeting() {
                    #expect(\(product)().greeting() == "Hello, world!")
                }
            }

            """
        }
    }

    static let gitignore = """
    .DS_Store
    .build/
    .swiftpm/
    *.xcodeproj/xcuserdata/
    DerivedData/
    Package.resolved

    """
}
