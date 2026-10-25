// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Swift 6 language mode is enabled on library, test, harness, and example targets.
// Do not set `defaultIsolation: MainActor` (SE-0476): EIP actors, background parse,
// and off-main search must stay nonisolated by default.

import Foundation
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

/// The JaCoCo agent and CLI that `Example/Umbra/Tools/JaCoCo/fetch.sh` downloads. They are not
/// committed, and a missing resource fails the whole build, so a checkout that has not run the
/// script just builds an Umbra that says "not bundled" for Run with Coverage.
let umbraJaCoCoResources: [Resource] = {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Example/Umbra/Tools/JaCoCo/build")
    return ["jacocoagent.jar", "jacococli.jar"].compactMap { name in
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            ? .copy("Tools/JaCoCo/build/\(name)") : nil
    }
}()

// Per-language grammar packs migrated from Hextech's Vendor/PenumbraLanguages.
// Each language is a trio: a C grammar target, a `*Queries` resource target,
// and a `*Penumbra` target that adds the `TreeSitterLanguage` factory.
// Only the deviations listed in the table differ per language; the generator
// below emits the otherwise identical trios.
private struct GrammarPack {
    let stem: String
    var extraQueryFiles: [String] = []
    var extraPenumbraDeps: [Target.Dependency] = []
    var exclude: [String] = []
    var cxxSearchPath = false
}

private let grammarPacks: [GrammarPack] = [
    GrammarPack(stem: "TOML"),
    GrammarPack(stem: "SQL", cxxSearchPath: true),
    GrammarPack(
        stem: "Swift",
        extraQueryFiles: ["highlights-swiftui.scm", "locals.scm"],
        exclude: ["LICENSE", "VERSION", "grammar.js", "src/node-types.json"]
    ),
    GrammarPack(stem: "Java", extraQueryFiles: ["tags.scm"]),
    GrammarPack(stem: "Kotlin", extraQueryFiles: ["tags.scm"]),
    GrammarPack(stem: "Go", extraQueryFiles: ["tags.scm"]),
    GrammarPack(stem: "Bash", cxxSearchPath: true),
    GrammarPack(stem: "HTTP", extraQueryFiles: ["injections.scm"]),
    GrammarPack(stem: "Mermaid"),
    GrammarPack(stem: "Rust"),
    GrammarPack(stem: "GitIgnore"),
    GrammarPack(stem: "Diff"),
    GrammarPack(stem: "C"),
    GrammarPack(
        stem: "Cpp",
        extraQueryFiles: ["injections.scm"],
        extraPenumbraDeps: ["TreeSitterCQueries"]
    ),
]

private let grammarPackTargets: [Target] = grammarPacks.flatMap { pack -> [Target] in
    let grammarName = "TreeSitter\(pack.stem)"
    let queriesName = "TreeSitter\(pack.stem)Queries"
    var queryResources: [Resource] = [.copy("highlights.scm")]
    queryResources += pack.extraQueryFiles.map { Resource.copy($0) }
    var penumbraDeps: [Target.Dependency] = [
        "Penumbra",
        .target(name: grammarName),
        .target(name: queriesName),
    ]
    penumbraDeps += pack.extraPenumbraDeps
    return [
        .target(
            name: grammarName,
            exclude: pack.exclude,
            cSettings: [.headerSearchPath("src")],
            cxxSettings: pack.cxxSearchPath ? [.headerSearchPath("src")] : nil
        ),
        .target(
            name: queriesName,
            resources: queryResources
        ),
        .target(
            name: "TreeSitter\(pack.stem)Penumbra",
            dependencies: penumbraDeps,
            swiftSettings: swift6
        ),
    ]
}

let package = Package(
    name: "Penumbra",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "Penumbra", targets: ["Penumbra"]),
        .library(name: "EditorIntelligence", targets: ["EditorIntelligence"]),
        .library(name: "EditorIntelligenceLSP", targets: ["EditorIntelligenceLSP"]),
        .library(name: "PenumbraGraphQLLanguage", targets: ["PenumbraGraphQLLanguage"]),
        .library(name: "PenumbraMarkdownLanguage", targets: ["PenumbraMarkdownLanguage"]),
        .library(name: "PenumbraLanguages", targets: ["PenumbraLanguages"]),
        .library(name: "LanguageSyntax", targets: ["LanguageSyntax"]),
        .library(name: "JavaIntelligence", targets: ["JavaIntelligence"]),
        .library(name: "SwiftIntelligence", targets: ["SwiftIntelligence"]),
        .library(name: "TypeScriptIntelligence", targets: ["TypeScriptIntelligence"]),
        .library(name: "HexKit", targets: ["HexKit"]),
        // Umbra's Xcode project links these through the root package. Referencing
        // `Packages/SubprocessKit` as well would declare the target twice in one package graph.
        .library(name: "SubprocessKit", targets: ["SubprocessKit"]),
        .library(name: "GitIntelligence", targets: ["GitIntelligence"])
    ],
    dependencies: [
        .package(path: "Packages/AgentKit"),
        .package(path: "Packages/AgentKitMLX"),
        .package(path: "Packages/AgentKitApple"),
        .package(path: "Packages/DatabaseKit"),
        .package(url: "https://github.com/ChimeHQ/LanguageClient", from: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        .package(url: "https://github.com/alex-cova/sunflower", from: "1.0.0"),
        .package(url: "https://github.com/alex-cova/DiagramKit", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/xcode-project-format", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "TreeSitter",
            path: "Packages/TreeSitter/lib",
            exclude: [
                "src/unicode/ICU_SHA",
                "src/unicode/README.md",
                "src/unicode/LICENSE",
                "src/wasm/stdlib-symbols.txt"
            ],
            sources: ["src/lib.c"],
            cSettings: [
                .headerSearchPath("src"),
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DEFAULT_SOURCE"),
                .define("_BSD_SOURCE"),
                .define("_DARWIN_C_SOURCE")
            ]
        ),
        .target(
            name: "PenumbraLuna",
            path: "Packages/Luna/Sources/Luna",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "EditorIntelligence", dependencies: [], exclude: ["CLAUDE.md"], swiftSettings: swift6),
        // Vendored as targets (not separate SPM packages) so editor consumers like Hextech do not
        // resolve SubprocessKit in their package graph.
        .target(
            name: "SubprocessKit",
            path: "Packages/SubprocessKit/Sources/SubprocessKit",
            swiftSettings: swift6
        ),
        .target(
            name: "GitIntelligence",
            dependencies: ["SubprocessKit"],
            path: "Packages/GitIntelligence/Sources/GitIntelligence",
            swiftSettings: swift6
        ),
        .target(
            name: "EditorIntelligenceLSP",
            dependencies: [
                "EditorIntelligence",
                .product(name: "LanguageClient", package: "LanguageClient"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
                .product(name: "JSONRPC", package: "JSONRPC")
            ],
            swiftSettings: swift6
        ),
        .target(name: "Penumbra", dependencies: [
            "EditorIntelligence",
            "PenumbraLuna",
            "TreeSitter"
        ], exclude: [
            "CLAUDE.md",
            "Documentation.docc",
            "TextView/Gutter/CLAUDE.md",
            "TextView/Keymap/CLAUDE.md",
            "Workbench/CLAUDE.md"
        ], resources: [
            .copy("PrivacyInfo.xcprivacy"),
            .process("TextView/Appearance/Theme.xcassets")
        ], swiftSettings: swift6),
        // Native Java indexing/completion engine: no dependency on Penumbra, only on
        // EditorIntelligence and the vendored tree-sitter-java grammar. See
        // Sources/JavaIntelligence/README.md for the architecture.
        .target(
            name: "LanguageSyntax",
            dependencies: [
                "EditorIntelligence",
                "TreeSitter"
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "JavaIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitter",
                "TreeSitterJava",
                .product(name: "FernflowerKit", package: "sunflower"),
                "SubprocessKit"
            ],
            exclude: [
                "CLAUDE.md",
                "Inspections/CLAUDE.md",
                "Profiling/CLAUDE.md",
                "Semantics/CLAUDE.md"
            ],
            swiftSettings: swift6
        ),
        // Syntactic Swift and TypeScript engines. They still parse through JavaIntelligence's
        // syntax types until LanguageSyntax exists (docs/LANGUAGE_PARITY_PLAN.md, phase 1).
        // Umbra-only wiring (support objects, SwiftPM, the palette) stays in the app target.
        .target(
            name: "SwiftIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitterSwift"
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "TypeScriptIntelligence",
            dependencies: [
                "EditorIntelligence",
                "LanguageSyntax",
                "TreeSitterTypeScript"
            ],
            swiftSettings: swift6
        ),
        // Byte model for the hex editor. No Penumbra, no AppKit. Umbra owns the view.
        .target(
            name: "HexKit",
            exclude: ["CLAUDE.md"],
            swiftSettings: swift6
        ),
        .executableTarget(name: "SmokeTest", dependencies: ["Penumbra", "PenumbraMarkdownLanguage"], swiftSettings: swift6),
        .executableTarget(
            name: "PerfHarness",
            dependencies: [
                "Penumbra",
                "EditorIntelligence",
                "JavaIntelligence",
                "SwiftIntelligence",
                "TypeScriptIntelligence",
                "LanguageSyntax",
                "PenumbraMarkdownLanguage",
                "PenumbraLanguages",
                "HexKit"
            ],
            path: "Tools/PerfHarness/Sources",
            swiftSettings: swift6
        ),
        // The agent evaluator: scripted tasks, a real model, a verdict from the project's own tests.
        .target(
            name: "AgentEvalKit",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                "SubprocessKit"
            ],
            path: "Tools/AgentEval/Sources/AgentEvalKit",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "AgentEval",
            dependencies: [
                "AgentEvalKit",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
            ],
            path: "Tools/AgentEval/Sources/AgentEval",
            swiftSettings: swift6
        ),
        // Umbra as an ACP agent on stdio (docs/ACP_PLAN.md Phase 2): any ACP client can drive
        // an AgentSession built from the user's configured provider.
        .executableTarget(
            name: "UmbraACP",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
            ],
            path: "Example/UmbraACP",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "AgentEvalTests",
            dependencies: ["AgentEvalKit", .product(name: "AgentKit", package: "AgentKit")],
            path: "Tools/AgentEval/Tests/AgentEvalTests",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "Umbra",
            dependencies: [
                "Penumbra",
                "PenumbraLanguages",
                "PenumbraMarkdownLanguage",
                "JavaIntelligence",
                "SwiftIntelligence",
                "TypeScriptIntelligence",
                "EditorIntelligenceLSP",
                "TreeSitter",
                "TreeSitterHTTP",
                "TreeSitterTypeScript",
                "TreeSitterSwift",
                "GitIntelligence",
                "SubprocessKit",
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "AgentKitMLX", package: "AgentKitMLX"),
                .product(name: "LocalModelStore", package: "AgentKitMLX"),
                .product(name: "AgentKitApple", package: "AgentKitApple"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "DiagramKit", package: "DiagramKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
                .product(name: "DatabaseKit", package: "DatabaseKit"),
                "HexKit"
            ],
            path: "Example/Umbra",
            exclude: [
                "CLAUDE.md",
                "Agent/CLAUDE.md",
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
                .copy("../umbra.png")
            ] + umbraJaCoCoResources,
            swiftSettings: swift6
        ),
        .target(name: "TestTreeSitterLanguages"),
        .target(name: "TreeSitterGraphQL", cSettings: [
            .headerSearchPath("src")
        ]),
        .target(
            name: "PenumbraGraphQLLanguage",
            dependencies: [
                "Penumbra",
                "TreeSitterGraphQL"
            ],
            resources: [
                .copy("highlights.scm")
            ],
            swiftSettings: swift6
        ),
        .target(name: "TreeSitterMarkdown", exclude: ["LICENSE", "VERSION"], cSettings: [
            .headerSearchPath("src")
        ]),
        .target(name: "TreeSitterMarkdownInline", exclude: ["LICENSE", "VERSION"], cSettings: [
            .headerSearchPath("src")
        ]),
        .target(
            name: "TreeSitterCSS",
            cSettings: [
                .headerSearchPath("src")
            ]
        ),
        .target(
            name: "TreeSitterTypeScript",
            cSettings: [
                .headerSearchPath("src")
            ]
        ),
    ] + grammarPackTargets + [
        .target(
            name: "PenumbraLanguages",
            dependencies: [
                "Penumbra",
                "TestTreeSitterLanguages",
                "TreeSitterCSS",
                "TreeSitterTypeScript",
                "PenumbraGraphQLLanguage",
                "PenumbraMarkdownLanguage",
                "TreeSitterTOMLPenumbra",
                "TreeSitterSQLPenumbra",
                "TreeSitterSwiftPenumbra",
                "TreeSitterJavaPenumbra",
                "TreeSitterKotlinPenumbra",
                "TreeSitterGoPenumbra",
                "TreeSitterBashPenumbra",
                "TreeSitterHTTPPenumbra",
                "TreeSitterMermaidPenumbra",
                "TreeSitterRustPenumbra",
                "TreeSitterCPenumbra",
                "TreeSitterCppPenumbra",
                "TreeSitterDiffPenumbra",
                "TreeSitterGitIgnorePenumbra"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "PenumbraMarkdownLanguage",
            dependencies: [
                "Penumbra",
                "TreeSitterMarkdown",
                "TreeSitterMarkdownInline"
            ],
            resources: [
                .copy("Queries")
            ],
            swiftSettings: swift6
        ),
        .testTarget(name: "PenumbraTests", dependencies: [
            "Penumbra",
            "EditorIntelligence",
            "LanguageSyntax",
            "EditorIntelligenceLSP",
            "TestTreeSitterLanguages",
            "PenumbraGraphQLLanguage",
            "PenumbraMarkdownLanguage",
            "PenumbraLanguages",
            "PenumbraLuna",
            "JavaIntelligence",
            "SwiftIntelligence",
            "TypeScriptIntelligence",
            "HexKit",
            "Umbra",
            "GitIntelligence",
            .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "AgentKitMLX", package: "AgentKitMLX"),
            .product(name: "LocalModelStore", package: "AgentKitMLX"),
            .product(name: "AgentKitApple", package: "AgentKitApple"),
            .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
            .product(name: "DatabaseKit", package: "DatabaseKit")
        ], exclude: ["Fixtures/SwiftCorpus", "Fixtures/TypeScriptCorpus"], resources: [.copy("Fixtures/Java"), .copy("Fixtures/Gradle"), .copy("Fixtures/JavaCompletionCorpus"), .copy("Fixtures/JavaNavigationCorpus"), .copy("Fixtures/JUnit"), .copy("Fixtures/JavaCoverage"), .copy("Fixtures/JavaProfiling"), .copy("Fixtures/JavaParityCorpus"), .copy("Fixtures/JavaCommandCorpus"), .copy("MermaidCorpus")], swiftSettings: swift6)
    ]
)
