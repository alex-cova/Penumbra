import Foundation
import XcodeProjectFormat

/// Xcode 27 project templates. The project is built as an `XCSchema.Project` and written with
/// Apple's XcodeProjectFormat library as `<Name>.xcodeproj/project.xcproj`, so the output is the
/// canonical JSON5 Xcode itself writes.
enum IDEXcodeProjectTemplates {
    static let all: [any IDEProjectTemplate] = [
        IDEXcodeProjectTemplate(kind: .macOSApp),
        IDEXcodeProjectTemplate(kind: .commandLineTool),
    ]
}

struct IDEXcodeProjectTemplate: IDEProjectTemplate {
    enum Kind: Sendable {
        case macOSApp
        case commandLineTool

        var productTypeID: String {
            switch self {
            case .macOSApp: "com.apple.product-type.application"
            case .commandLineTool: "com.apple.product-type.tool"
            }
        }

        var productFileType: String {
            switch self {
            case .macOSApp: "wrapper.application"
            case .commandLineTool: "compiled.mach-o.executable"
            }
        }

        func productFileName(_ product: String) -> String {
            switch self {
            case .macOSApp: product + ".app"
            case .commandLineTool: product
            }
        }
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .macOSApp: "swift.xcode.macos-app"
        case .commandLineTool: "swift.xcode.command-line-tool"
        }
    }

    var family: IDEProjectFamily { .swift }

    var title: String {
        switch kind {
        case .macOSApp: "macOS App"
        case .commandLineTool: "Command Line Tool"
        }
    }

    var summary: String {
        switch kind {
        case .macOSApp: "A SwiftUI app in an Xcode project (project.xcproj), sandboxed with the hardened runtime."
        case .commandLineTool: "A command-line tool in an Xcode project (project.xcproj)."
        }
    }

    var systemImage: String {
        switch kind {
        case .macOSApp: "macwindow"
        case .commandLineTool: "terminal"
        }
    }

    var fields: Set<IDENewProjectField> {
        switch kind {
        case .macOSApp: [.organizationIdentifier, .minimumMacOS]
        case .commandLineTool: [.organizationIdentifier, .minimumMacOS]
        }
    }

    func primaryFile(for options: IDENewProjectOptions) -> String? {
        let product = options.productName
        switch kind {
        case .macOSApp: return "\(product)/ContentView.swift"
        case .commandLineTool: return "\(product)/main.swift"
        }
    }

    /// The template's logic-test suite: self-contained XCTest, no host app, so `xcodebuild test`
    /// runs it on the Mac with no signing identity and no destination.
    static func testsSource(_ product: String) -> String {
        """
        import XCTest

        final class \(product)Tests: XCTestCase {
            func testExample() throws {
                XCTAssertEqual(1 + 1, 2)
            }

            func testPerformanceExample() throws {
                measure {
                    _ = (0 ..< 1_000).reduce(0, +)
                }
            }
        }
        """
    }

    func files(for options: IDENewProjectOptions) throws -> [IDEGeneratedFile] {
        let product = options.productName
        let project = try IDEXcodeProjectBuilder.project(kind: kind, options: options)
        var files = [
            IDEGeneratedFile(
                path: "\(options.name).xcodeproj/project.xcproj",
                data: try project.jsonRepresentation()
            ),
            IDEGeneratedFile(path: ".gitignore", text: Self.gitignore),
            IDEGeneratedFile(path: "Tests/\(product)Tests.swift", text: Self.testsSource(product)),
        ]
        switch kind {
        case .macOSApp:
            files += [
                IDEGeneratedFile(path: "\(product)/\(product)App.swift", text: appSource(product)),
                IDEGeneratedFile(path: "\(product)/ContentView.swift", text: contentViewSource),
                IDEGeneratedFile(path: "\(product)/Assets.xcassets/Contents.json", text: Self.assetInfo),
                IDEGeneratedFile(
                    path: "\(product)/Assets.xcassets/AccentColor.colorset/Contents.json",
                    text: Self.accentColor
                ),
                IDEGeneratedFile(
                    path: "\(product)/Assets.xcassets/AppIcon.appiconset/Contents.json",
                    text: Self.appIcon
                ),
            ]
        case .commandLineTool:
            files.append(IDEGeneratedFile(
                path: "\(product)/main.swift",
                text: "print(\"Hello, world!\")\n"
            ))
        }
        return files
    }

    private func appSource(_ product: String) -> String {
        """
        import SwiftUI

        @main
        struct \(product)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        """
    }

    private var contentViewSource: String {
        """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Image(systemName: "globe")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                    Text("Hello, world!")
                }
                .padding()
            }
        }

        #Preview {
            ContentView()
        }

        """
    }

    private static let gitignore = """
    .DS_Store
    xcuserdata/
    DerivedData/
    build/
    .build/

    """

    private static let assetInfo = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    private static let accentColor = """
    {
      "colors" : [
        {
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    private static let appIcon: String = {
        let sizes: [(String, Int)] = [("16x16", 1), ("16x16", 2), ("32x32", 1), ("32x32", 2),
                                      ("128x128", 1), ("128x128", 2), ("256x256", 1), ("256x256", 2),
                                      ("512x512", 1), ("512x512", 2)]
        let images = sizes.map { size, scale in
            """
                {
                  "idiom" : "mac",
                  "scale" : "\(scale)x",
                  "size" : "\(size)"
                }
            """
        }.joined(separator: ",\n")
        return """
        {
          "images" : [
        \(images)
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
    }()
}

/// Assembles the `XCSchema.Project` of an Xcode template. Object IDs are derived from the project
/// name, so the same options always give the same bytes.
enum IDEXcodeProjectBuilder {
    static func project(
        kind: IDEXcodeProjectTemplate.Kind,
        options: IDENewProjectOptions
    ) throws -> XCSchema.Project {
        let product = options.productName
        let targetName = product
        let productFile = kind.productFileName(product)
        let testTargetName = product + "Tests"
        let testProductFile = testTargetName + ".xctest"

        let sourceFolder = XCSchema.Folder(
            objectID: id("folder", product),
            path: try XCSchema.FilePath(base: .group, path: product),
            targets: [XCSchema.LocalTargetReference(targetName: targetName)],
            membershipExceptions: [],
            explicitFileTypes: [:],
            explicitOpaqueFolders: [],
            includeInIndex: nil
        )

        let testsFolder = XCSchema.Folder(
            objectID: id("tests-folder", product),
            path: try XCSchema.FilePath(base: .group, path: "Tests"),
            targets: [XCSchema.LocalTargetReference(targetName: testTargetName)],
            membershipExceptions: [],
            explicitFileTypes: [:],
            explicitOpaqueFolders: [],
            includeInIndex: nil
        )

        let productReference = XCSchema.FileReference(
            objectID: id("product", product),
            path: try XCSchema.FilePath(base: .buildProducts, path: productFile),
            explicitFileType: XCSchema.FileTypeID(fileTypeID: kind.productFileType),
            expectedSignature: nil,
            textEncoding: nil,
            lineEnding: nil,
            includeInIndex: false,
            buildFiles: []
        )
        let testProductReference = XCSchema.FileReference(
            objectID: id("test-product", product),
            path: try XCSchema.FilePath(base: .buildProducts, path: testProductFile),
            explicitFileType: XCSchema.FileTypeID(fileTypeID: "wrapper.cfbundle"),
            expectedSignature: nil,
            textEncoding: nil,
            lineEnding: nil,
            includeInIndex: false,
            buildFiles: []
        )
        let productsGroup = XCSchema.Group(
            objectID: id("products", product),
            name: "Products",
            path: try XCSchema.FilePath(base: .group, path: ""),
            includeInIndex: nil,
            children: [.fileReference(productReference), .fileReference(testProductReference)]
        )

        var phases: [XCSchema.BuildPhase] = [
            .sources(XCSchema.BuildPhaseProperties(objectID: id("sources", product), name: nil)),
            .frameworks(XCSchema.BuildPhaseProperties(objectID: id("frameworks", product), name: nil)),
        ]
        if kind == .macOSApp {
            phases.append(.resources(XCSchema.BuildPhaseProperties(objectID: id("resources", product), name: nil)))
        }

        let target = XCSchema.CommonTargetProperties(
            name: targetName,
            objectID: id("target", product),
            configurationListDebugID: nil,
            dependencies: [],
            buildPhases: phases,
            buildRules: [],
            specializedConfigurations: [],
            buildSettings: targetSettings(kind: kind, options: options),
            product: .namePath(XCSchema.NamePath(components: [.child("Products"), .child(productFile)])),
            productTypeID: XCSchema.ProductTypeID(productTypeID: kind.productTypeID),
            testHostTarget: nil,
            legacyProvisioningStyle: nil,
            legacyTeamID: nil,
            lastSwiftUpdateCheck: nil,
            lastSwiftMigration: nil,
            packageProductTargetMembers: []
        )

        // A logic-test bundle: no host app, so it runs on the Mac with no signing identity.
        let testTarget = XCSchema.CommonTargetProperties(
            name: testTargetName,
            objectID: id("test-target", product),
            configurationListDebugID: nil,
            dependencies: [],
            buildPhases: [
                .sources(XCSchema.BuildPhaseProperties(objectID: id("test-sources", product), name: nil)),
                .frameworks(XCSchema.BuildPhaseProperties(objectID: id("test-frameworks", product), name: nil)),
            ],
            buildRules: [],
            specializedConfigurations: [],
            buildSettings: testTargetSettings(options: options),
            product: .namePath(XCSchema.NamePath(components: [.child("Products"), .child(testProductFile)])),
            productTypeID: XCSchema.ProductTypeID(productTypeID: "com.apple.product-type.bundle.unit-test"),
            testHostTarget: nil,
            legacyProvisioningStyle: nil,
            legacyTeamID: nil,
            lastSwiftUpdateCheck: nil,
            lastSwiftMigration: nil,
            packageProductTargetMembers: []
        )

        let debug = XCSchema.ConfigurationName(name: "Debug")
        let release = XCSchema.ConfigurationName(name: "Release")
        return XCSchema.Project(
            objectID: id("project", product),
            rootGroupDebugID: nil,
            configurationListDebugID: nil,
            topLevelReferences: [.folder(sourceFolder), .folder(testsFolder), .group(productsGroup)],
            packages: [],
            configurations: [
                XCSchema.Configuration(name: debug, file: nil, objectID: nil),
                XCSchema.Configuration(name: release, file: nil, objectID: nil),
            ],
            buildSettings: projectSettings(options: options),
            defaultConfigurationName: release,
            targets: [.native(target), .native(testTarget)],
            localizationInfo: XCSchema.ProjectLocalizationInfo(
                development: XCSchema.Language(languageID: "en"),
                supported: []
            ),
            requiredCapabilities: [],
            buildIndependentTargetsInParallel: true,
            lastUpgradeCheck: nil,
            lastSwiftUpdateCheck: nil,
            lastSwiftMigration: nil,
            organizationName: nil,
            classPrefix: nil,
            productsGroup: .namePath(XCSchema.NamePath(components: [.child("Products")])),
            importedProducts: []
        )
    }

    // MARK: - Settings

    private static func projectSettings(options: IDENewProjectOptions) -> [String: XCSchema.BuildSetting] {
        [
            "SDKROOT": .string("macosx"),
            "MACOSX_DEPLOYMENT_TARGET": .string(options.minimumMacOS),
            "SWIFT_VERSION": .string("6.0"),
            "CLANG_ENABLE_MODULES": .string("YES"),
            "ENABLE_USER_SCRIPT_SANDBOXING": .string("YES"),
            "ENABLE_STRICT_OBJC_MSGSEND": .string("YES"),
            "GCC_C_LANGUAGE_STANDARD": .string("gnu17"),
            "LOCALIZATION_PREFERS_STRING_CATALOGS": .string("YES"),
            "DEBUG_INFORMATION_FORMAT[config=Debug]": .string("dwarf"),
            "DEBUG_INFORMATION_FORMAT[config=Release]": .string("dwarf-with-dsym"),
            "ONLY_ACTIVE_ARCH[config=Debug]": .string("YES"),
            "SWIFT_OPTIMIZATION_LEVEL[config=Debug]": .string("-Onone"),
            "SWIFT_COMPILATION_MODE[config=Release]": .string("wholemodule"),
            "ENABLE_TESTABILITY[config=Debug]": .string("YES"),
        ]
    }

    private static func testTargetSettings(options: IDENewProjectOptions) -> [String: XCSchema.BuildSetting] {
        [
            "PRODUCT_NAME": .string("$(TARGET_NAME)"),
            "PRODUCT_BUNDLE_IDENTIFIER": .string(options.bundleIdentifier + ".tests"),
            "GENERATE_INFOPLIST_FILE": .string("YES"),
            "CODE_SIGN_STYLE": .string("Automatic"),
            "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"]),
        ]
    }

    private static func targetSettings(
        kind: IDEXcodeProjectTemplate.Kind,
        options: IDENewProjectOptions
    ) -> [String: XCSchema.BuildSetting] {
        var settings: [String: XCSchema.BuildSetting] = [
            "PRODUCT_NAME": .string("$(TARGET_NAME)"),
            "PRODUCT_BUNDLE_IDENTIFIER": .string(options.bundleIdentifier),
            "CODE_SIGN_STYLE": .string("Automatic"),
            "ENABLE_HARDENED_RUNTIME": .string("YES"),
            "SWIFT_EMIT_LOC_STRINGS": .string("YES"),
        ]
        if kind == .macOSApp {
            settings["GENERATE_INFOPLIST_FILE"] = .string("YES")
            settings["INFOPLIST_KEY_NSHumanReadableCopyright"] = .string("")
            settings["INFOPLIST_KEY_NSPrincipalClass"] = .string("NSApplication")
            settings["ENABLE_APP_SANDBOX"] = .string("YES")
            settings["ENABLE_USER_SELECTED_FILES"] = .string("readonly")
            settings["ENABLE_PREVIEWS"] = .string("YES")
            settings["COMBINE_HIDPI_IMAGES"] = .string("YES")
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = .string("AppIcon")
            settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = .string("AccentColor")
            settings["MARKETING_VERSION"] = .string("1.0")
            settings["CURRENT_PROJECT_VERSION"] = .string("1")
            settings["LD_RUNPATH_SEARCH_PATHS"] = .array(["$(inherited)", "@executable_path/../Frameworks"])
        }
        return settings
    }

    /// A stable 16-hex-digit identifier (FNV-1a over the role and the product name).
    private static func id(_ role: String, _ product: String) -> XCSchema.ObjectID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (role + ":" + product).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return XCSchema.ObjectID(String(format: "%016llX", hash))
    }
}
