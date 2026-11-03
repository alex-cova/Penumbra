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
    products: [
        .executable(name: "umbra-agent", targets: ["UmbraAgent"]),
    ],
    dependencies: [
        .package(name: "Penumbra", path: ".."),
        .package(path: "../Packages/AgentKit"),
        .package(path: "../Packages/AgentKitMLX"),
        .package(path: "../Packages/AgentKitApple"),
        .package(path: "../Packages/DatabaseKit"),
        .package(url: "https://github.com/alex-cova/DiagramKit", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/xcode-project-format", from: "0.1.0")
    ],
    targets: [
        // Prebuilt libghostty-vt (Ghostty commit 4a4fc017940bec38c93b278c10c6a18c591f3e63,
        // Zig 0.17.0, macOS arm64+x86_64 only). Rebuild procedure and gate
        // resolutions live in .agents/plans/2026-10-27-ghostty-terminal.md (G1).
        .binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework"),
        // Headless agent pieces shared by the app, the CLI and the ACP agent
        // (docs/harness/agent-harness-6.md Phase 1): the provider factory, permission
        // files, command runner/environment, output scrubber, sandbox, key store, and
        // the host-independent `run_command` plus the headless run driver.
        .target(
            name: "UmbraAgentSupport",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
                .product(name: "SubprocessKit", package: "Penumbra"),
            ],
            swiftSettings: swift6
        ),
        // Umbra as an ACP agent on stdio (docs/ACP_PLAN.md Phase 2): any ACP client can drive
        // an AgentSession built from the user's configured provider.
        .executableTarget(
            name: "UmbraACP",
            dependencies: [
                "UmbraAgentSupport",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
            ],
            swiftSettings: swift6
        ),
        // Headless agent CLI (docs/harness/agent-harness-6.md Phase 2): `umbra-agent run`
        // for scripts, git hooks and CI. Links the app's UI never: Foundation only.
        .executableTarget(
            name: "UmbraAgent",
            dependencies: [
                "UmbraAgentSupport",
            ],
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: [
                "UmbraAgentSupport",
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
                "GhosttyVt",
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
                .copy("Agent/Skills"),
                .copy("../../umbra.png")
            ] + umbraJaCoCoResources,
            swiftSettings: swift6
        ),
        .testTarget(
            name: "UmbraTests",
            dependencies: [
                "Umbra",
                "UmbraAgentSupport",
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
