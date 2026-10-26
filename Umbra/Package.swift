// swift-tools-version: 6.2
// Umbra, the macOS editor app. The engine and the IDE-intelligence libraries live in the root
// package (`..`); this package owns the app, its ACP agent and everything the libraries must not
// link: the agent harness (AgentKit, MLX, Apple Intelligence), the terminal, Sparkle, the
// diagram renderer and the database client.
//
// Swift 6 language mode is enabled on every target. Do not set `defaultIsolation: MainActor`
// (SE-0476): the engine's actors and background parses must stay nonisolated by default.

import Foundation
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

/// The JaCoCo agent and CLI that `Sources/Umbra/Tools/JaCoCo/fetch.sh` downloads. They are not
/// committed, and a missing resource fails the whole build, so a checkout that has not run the
/// script just builds an Umbra that says "not bundled" for Run with Coverage.
let umbraJaCoCoResources: [Resource] = {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Sources/Umbra/Tools/JaCoCo/build")
    return ["jacocoagent.jar", "jacococli.jar"].compactMap { name in
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            ? .copy("Tools/JaCoCo/build/\(name)") : nil
    }
}()

let package = Package(
    name: "Umbra",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(name: "Penumbra", path: ".."),
        .package(path: "../Packages/AgentKit"),
        .package(path: "../Packages/AgentKitMLX"),
        .package(path: "../Packages/AgentKitApple"),
        .package(path: "../Packages/DatabaseKit"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        .package(url: "https://github.com/alex-cova/DiagramKit", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/xcode-project-format", from: "0.1.0")
    ],
    targets: [
        // Umbra as an ACP agent on stdio (docs/ACP_PLAN.md Phase 2): any ACP client can drive
        // an AgentSession built from the user's configured provider.
        .executableTarget(
            name: "UmbraACP",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
            ],
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: [
                .product(name: "Penumbra", package: "Penumbra"),
                .product(name: "PenumbraLanguages", package: "Penumbra"),
                .product(name: "PenumbraMarkdownLanguage", package: "Penumbra"),
                .product(name: "EditorIntelligence", package: "Penumbra"),
                .product(name: "EditorIntelligenceLSP", package: "Penumbra"),
                .product(name: "JavaIntelligence", package: "Penumbra"),
                .product(name: "SwiftIntelligence", package: "Penumbra"),
                .product(name: "TypeScriptIntelligence", package: "Penumbra"),
                .product(name: "GitIntelligence", package: "Penumbra"),
                .product(name: "SubprocessKit", package: "Penumbra"),
                .product(name: "HexKit", package: "Penumbra"),
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "DiagramKit", package: "DiagramKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
                .product(name: "DatabaseKit", package: "DatabaseKit")
            ],
            path: "Sources/Umbra",
            exclude: [
                "Agent/CLAUDE.md",
                "Bookmarks/CLAUDE.md",
                "Coverage/CLAUDE.md",
                "Diagrams/CLAUDE.md",
                "Diff/CLAUDE.md",
                "Git/CLAUDE.md",
                "HTTP/CLAUDE.md",
                "Inspections/CLAUDE.md",
                "Languages/CLAUDE.md",
                "LocalHistory/CLAUDE.md",
                "Profiler/CLAUDE.md",
                "Projects/CLAUDE.md",
                "ProjectWizard/CLAUDE.md",
                "Run/CLAUDE.md",
                "Saving/CLAUDE.md",
                "Swift/CLAUDE.md",
                "SwiftUIPreview/CLAUDE.md",
                "TextTools/CLAUDE.md",
                "SplitView/LICENSE",
                "SplitView/README.md",
                "Tools/JavaDebugAdapter/build.sh",
                "Tools/JavaDebugAdapter/build/classes",
                "Tools/JavaDebugAdapter/build/test-classes",
                "Tools/JavaDebugAdapter/build/test-sources.txt",
                "Tools/JavaDebugAdapter/build/sources.txt",
                "Tools/JavaDebugAdapter/src",
                "Tools/JavaAnalysisServer/build.sh",
                "Tools/JavaAnalysisServer/build/classes",
                "Tools/JavaAnalysisServer/build/sources.txt",
                "Tools/JavaAnalysisServer/src",
                "Tools/JaCoCo/fetch.sh"
            ],
            resources: [
                .copy("Tools/JavaDebugAdapter/build/java-debug-adapter.jar"),
                .copy("Tools/JavaAnalysisServer/build/java-analysis-server.jar"),
                .copy("../../umbra.png")
            ] + umbraJaCoCoResources,
            swiftSettings: swift6
        ),
        .testTarget(
            name: "UmbraTests",
            dependencies: [
                "Umbra",
                .product(name: "Penumbra", package: "Penumbra"),
                .product(name: "PenumbraLanguages", package: "Penumbra"),
                .product(name: "EditorIntelligence", package: "Penumbra"),
                .product(name: "EditorIntelligenceLSP", package: "Penumbra"),
                .product(name: "JavaIntelligence", package: "Penumbra"),
                .product(name: "SwiftIntelligence", package: "Penumbra"),
                .product(name: "TypeScriptIntelligence", package: "Penumbra"),
                .product(name: "GitIntelligence", package: "Penumbra"),
                .product(name: "SubprocessKit", package: "Penumbra"),
                .product(name: "HexKit", package: "Penumbra"),
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
                .product(name: "DiagramKit", package: "DiagramKit"),
                .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
                .product(name: "DatabaseKit", package: "DatabaseKit")
            ],
            exclude: ["markdown-preview-test.md"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift6
        )
    ]
)
