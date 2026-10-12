import Foundation

/// One command the preview pipeline runs. The tool is named, not resolved: the caller finds
/// `swift` and `swiftc` in the toolchain it uses for the project.
public struct SwiftPreviewCommand: Sendable, Equatable {
    public enum Tool: Sendable, Equatable { case swift, swiftc, nm, xcodebuild }

    public var tool: Tool
    public var arguments: [String]

    public init(tool: Tool, arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }
}

/// What it takes to show one preview of one Swift file in a SwiftPM package: the commands, in
/// order, and the generated sources. Pure: nothing is run or written here, so the whole recipe is
/// testable as values.
///
///     1. `buildCommand`                       the package's target, into its own scratch path
///     2. `binPathCommand`                     where its objects and modules are
///     3. `supportCommand`                     the module the host and the thunks share (once)
///     4. `hostCommand(binPath:objects:)`      the host, linked with the target's objects
///     5. `thunkCommand(binPath:generation:)`  the preview's view, as a dylib
///
/// After that, an edit to the file needs just step 5: the thunk of ``ThunkMode/copy`` holds the
/// file's current text, so the preview shows the edit without building the package again.
///
/// The recipe is the one proved in `Tools/PreviewSpike` and described in
/// `docs/SWIFTUI_PREVIEW_PLAN.md`.
public struct SwiftPreviewBuildPlan: Sendable, Equatable {
    /// What builds the file's target.
    public enum BuildSystem: Sendable, Equatable {
        /// `swift build --target`, in the directory of `Package.swift`.
        case swiftPM
        /// `xcodebuild -target`, for the `.xcodeproj` at this path.
        case xcode(project: String)
    }

    public struct Job: Sendable, Equatable {
        /// The directory of `Package.swift`, or of the `.xcodeproj` for an Xcode project.
        public var packageRoot: String
        /// SwiftPM's `--scratch-path` for preview builds: kept apart so the project's own `.build` is never invalidated.
        public var scratchPath: String
        /// Where the plan puts what it generates (host source, thunks, frames).
        public var workDirectory: String
        /// The SwiftPM target that contains the file.
        public var targetName: String
        /// The Swift file as it is on disk (for `#sourceLocation`, so build errors point at it).
        public var sourcePath: String
        /// The buffer the block was extracted from.
        public var sourceText: String
        /// `import` lines of that file, as written.
        public var imports: [String]
        public var block: SwiftPreviewBlock
        /// `14.0`: the lowest macOS the thunks and the host are compiled for.
        public var deploymentTarget: String
        public var architecture: String
        public var buildSystem: BuildSystem

        public init(
            packageRoot: String, scratchPath: String, workDirectory: String, targetName: String,
            sourcePath: String, sourceText: String, imports: [String], block: SwiftPreviewBlock,
            deploymentTarget: String = "14.0", architecture: String = "arm64", buildSystem: BuildSystem = .swiftPM
        ) {
            self.packageRoot = packageRoot
            self.scratchPath = scratchPath
            self.workDirectory = workDirectory
            self.targetName = targetName
            self.sourcePath = sourcePath
            self.sourceText = sourceText
            self.imports = imports
            self.block = block
            self.deploymentTarget = deploymentTarget
            self.architecture = architecture
            self.buildSystem = buildSystem
        }
    }

    public var job: Job

    public init(job: Job) {
        self.job = job
    }

    // MARK: Names

    /// SwiftPM names a module after its target with every character that is not valid in an
    /// identifier replaced by `_`.
    public static func moduleName(forTarget target: String) -> String {
        var name = String(target.unicodeScalars.map { scalar -> Character in
            let isLetter = (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            return isLetter || isDigit || scalar == "_" ? Character(scalar) : "_"
        })
        if let first = name.unicodeScalars.first, first.value >= 0x30, first.value <= 0x39 { name = "_" + name }
        return name
    }

    public var moduleName: String { Self.moduleName(forTarget: job.targetName) }

    /// The macOS target triple of every command.
    public var targetTriple: String { "\(job.architecture)-apple-macos\(job.deploymentTarget)" }

    // MARK: Paths

    public var hostSourcePath: String { job.workDirectory + "/host/" + SwiftPreviewHostSource.fileName }

    public func thunkSourcePath(generation: Int) -> String { job.workDirectory + "/thunks/Thunk\(generation).swift" }

    public func thunkLibraryPath(generation: Int) -> String { job.workDirectory + "/thunks/libThunk\(generation).dylib" }

    public func framePath(generation: Int) -> String { job.workDirectory + "/frames/frame\(generation).png" }

    public var socketPath: String { job.workDirectory + "/host.sock" }

    /// The shared module, per version of its source, so a changed source never meets an old dylib.
    public var supportDirectory: String { job.workDirectory + "/support-v\(SwiftPreviewSupportSource.version)" }

    public var supportSourcePath: String { supportDirectory + "/" + SwiftPreviewSupportSource.fileName }

    public var supportLibraryPath: String { supportDirectory + "/libUmbraPreviewSupport.dylib" }

    // MARK: Commands

    /// The flags the project is built with: `-enable-testing` for `@testable` access,
    /// `-enable-private-imports` for `@_private(sourceFile:) import`, and `-enable-implicit-dynamic`
    /// so a later thunk can replace a body without a relink.
    static let compilerFlags = [
        "-Xswiftc", "-enable-testing",
        "-Xswiftc", "-Xfrontend", "-Xswiftc", "-enable-implicit-dynamic",
        "-Xswiftc", "-Xfrontend", "-Xswiftc", "-enable-private-imports"
    ]

    /// Builds the file's target and what it depends on, and nothing else: another target of the
    /// package that does not compile does not stop the preview.
    public var buildCommand: SwiftPreviewCommand {
        switch job.buildSystem {
        case .swiftPM:
            return SwiftPreviewCommand(tool: .swift, arguments: [
                "build", "--package-path", job.packageRoot, "--scratch-path", job.scratchPath,
                "--target", job.targetName
            ] + Self.compilerFlags)
        case .xcode(let project):
            // Products and intermediates in a directory of their own, for the host's architecture
            // only (a fat build would leave two of every object), unsigned.
            return SwiftPreviewCommand(tool: .xcodebuild, arguments: [
                "-project", project, "-target", job.targetName, "-configuration", "Debug",
                "SYMROOT=" + job.scratchPath + "/Products", "OBJROOT=" + job.scratchPath + "/Intermediates",
                "ARCHS=" + job.architecture, "ONLY_ACTIVE_ARCH=YES", "ENABLE_TESTABILITY=YES",
                "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
                "OTHER_SWIFT_FLAGS=$(inherited) -enable-testing -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports",
                "build"
            ])
        }
    }

    /// Where an Xcode build leaves its products, known without asking; nil for SwiftPM.
    public var knownBinPath: String? {
        if case .xcode = job.buildSystem { return job.scratchPath + "/Products/Debug" }
        return nil
    }

    /// Where an Xcode build leaves its per-file objects; nil for SwiftPM.
    public var intermediatesPath: String? {
        if case .xcode = job.buildSystem { return job.scratchPath + "/Intermediates" }
        return nil
    }

    /// Prints the directory the build leaves its objects and `.swiftmodule`s in. It differs between
    /// toolchains (`.build/out/Products/Debug` with Swift 6.4's engine), so it is asked for.
    public var binPathCommand: SwiftPreviewCommand {
        SwiftPreviewCommand(tool: .swift, arguments: [
            "build", "--package-path", job.packageRoot, "--scratch-path", job.scratchPath,
            "--show-bin-path"
        ] + Self.compilerFlags)
    }

    /// The support module as a dylib and a `.swiftmodule`. Compiled with implicit dynamic so a thunk
    /// can replace `UmbraPreview.content()`. Needed once per work directory.
    public var supportCommand: SwiftPreviewCommand {
        SwiftPreviewCommand(tool: .swiftc, arguments: [
            "-emit-library", "-emit-module", "-parse-as-library",
            "-module-name", SwiftPreviewSupportSource.moduleName,
            "-emit-module-path", supportDirectory + "/UmbraPreviewSupport.swiftmodule",
            "-target", targetTriple, "-swift-version", "5",
            "-Xfrontend", "-enable-implicit-dynamic",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libUmbraPreviewSupport.dylib",
            "-o", supportLibraryPath, supportSourcePath
        ])
    }

    /// The host, linked with the objects of the project. They are linked whole, so every type the
    /// thunks name is in the process, and the host sits next to them so `Bundle.module` finds the
    /// resource bundles.
    public func hostCommand(binPath: String, objects: [String], modulePaths: [String] = []) -> SwiftPreviewCommand {
        var arguments = [
            "-target", targetTriple, "-swift-version", "5",
            "-I", binPath, "-L", binPath,
            "-I", supportDirectory, "-L", supportDirectory, "-lUmbraPreviewSupport",
            "-Xlinker", "-rpath", "-Xlinker", binPath,
            "-Xlinker", "-rpath", "-Xlinker", supportDirectory,
            "-o", binPath + "/UmbraPreviewHost", hostSourcePath
        ]
        for path in modulePaths { arguments.append(contentsOf: ["-I", path]) }
        arguments.append(contentsOf: objects.sorted())
        return SwiftPreviewCommand(tool: .swiftc, arguments: arguments)
    }

    /// Lists the global symbols the objects define, to find the one that has `main`.
    public func definedSymbolsCommand(objects: [String]) -> SwiftPreviewCommand {
        SwiftPreviewCommand(tool: .nm, arguments: ["-gU"] + objects.sorted())
    }

    /// The preview's view, as a dylib the host `dlopen`s. Its undefined symbols (the project's
    /// types) resolve against the host. Each generation has its own module name, so loading a
    /// second one never meets the first one's types.
    public func thunkCommand(binPath: String, generation: Int, modulePaths: [String] = []) -> SwiftPreviewCommand {
        var arguments = [
            "-emit-library", "-module-name", "UmbraPreviewThunk\(generation)",
            "-target", targetTriple, "-swift-version", "5",
            "-I", binPath, "-F", binPath, "-I", supportDirectory
        ]
        for path in modulePaths { arguments.append(contentsOf: ["-I", path]) }
        arguments += [
            "-enable-testing", "-Xfrontend", "-enable-private-imports",
            "-Xfrontend", "-disable-previous-implementation-calls-in-dynamic-replacements",
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            "-o", thunkLibraryPath(generation: generation), thunkSourcePath(generation: generation)
        ]
        return SwiftPreviewCommand(tool: .swiftc, arguments: arguments)
    }

    // MARK: Sources

    public var hostSource: String { SwiftPreviewHostSource.text }

    public enum ThunkMode: Sendable, Equatable {
        /// The thunk holds a copy of the whole file, so its types are new ones and show the file as
        /// it is now (not what the package was built from). Names it declares shadow the imported
        /// module's. This is what makes an edit visible without a build.
        case copy
        /// The thunk names the types the package was built with, through `@_private import`. It shows
        /// the file as it was built; it is what remains when the file cannot be compiled as a copy
        /// (a duplicate conformance, `@main`).
        case imported
    }

    /// The thunk: the preview's content and the entry point the host calls.
    ///
    /// The content replaces `UmbraPreview.content()` of the support module. A preview with no
    /// `@Previewable` state is inlined as a `@ViewBuilder` function; with `@Previewable` state it
    /// is a wrapper struct of the thunk's own.
    public func thunkSource(generation _: Int = 0, mode: ThunkMode = .imported) -> String {
        let file = (job.sourcePath as NSString).lastPathComponent
        var lines: [String] = []
        switch mode {
        case .imported:
            lines.append("@_private(sourceFile: \"\(Self.escaped(file))\") import \(moduleName)")
        case .copy:
            lines.append("@testable import \(moduleName)")
        }
        lines.append("import SwiftUI")
        lines.append("import AppKit")
        lines.append("import \(SwiftPreviewSupportSource.moduleName)")
        if mode == .imported {
            for statement in job.imports where Self.importedModule(of: statement) != moduleName {
                guard let module = Self.importedModule(of: statement),
                      !["SwiftUI", "AppKit", SwiftPreviewSupportSource.moduleName].contains(module) else { continue }
                if !lines.contains(statement) { lines.append(statement) }
            }
        }
        lines.append("")
        if mode == .copy {
            // The file as written, line for line (so diagnostics land on its own lines), with the
            // `#Preview` blocks blanked: the macro registers previews this process does not use.
            lines.append("#sourceLocation(file: \"\(Self.escaped(job.sourcePath))\", line: 1)")
            lines.append(Self.blankingPreviewMacros(in: job.sourceText))
            lines.append("")
            lines.append("#sourceLocation()")
        }

        let content: String
        switch job.block.kind {
        case .macro:
            let text = Self.text(of: job.block.contentBytes, in: job.sourceText)
            let line = Self.line(ofByte: job.block.contentBytes.lowerBound, in: job.sourceText)
            content = "#sourceLocation(file: \"\(Self.escaped(job.sourcePath))\", line: \(line))\n\(text)\n#sourceLocation()"
        case .provider(let typeName):
            content = "        VStack { \(typeName).previews }"
        }
        let replacedContent: String
        if job.block.previewables.isEmpty {
            lines.append("@ViewBuilder private func _umbraPreviewContent() -> some View {")
            lines.append(content)
            lines.append("}")
            replacedContent = "AnyView(_umbraPreviewContent())"
        } else {
            lines.append("struct _UmbraPreviewWrapper: View {")
            for previewable in job.block.previewables { lines.append("    " + previewable.declarationText) }
            lines.append("    var body: some View {")
            lines.append(content)
            lines.append("    }")
            lines.append("}")
            replacedContent = "AnyView(_UmbraPreviewWrapper())"
        }
        lines.append("")
        lines.append("extension UmbraPreview {")
        lines.append("    @_dynamicReplacement(for: content())")
        lines.append("    static func __umbra_content() -> AnyView { \(replacedContent) }")
        lines.append("}")
        lines.append("")
        lines.append("@_cdecl(\"umbra_preview_make_view\")")
        lines.append("public func _umbraPreviewMakeView() -> UnsafeMutableRawPointer {")
        lines.append("    MainActor.assumeIsolated {")
        lines.append("        let view = NSHostingView(rootView: AnyView(UmbraPreviewRoot()))")
        lines.append("        view.sizingOptions = []")
        lines.append("        return Unmanaged.passRetained(view as NSView).toOpaque()")
        lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// `source` with every `#Preview` macro call replaced by spaces, newlines kept.
    static func blankingPreviewMacros(in source: String) -> String {
        var bytes = Array(source.utf8)
        for block in SwiftPreviewExtractor.extract(from: source) where block.kind == .macro {
            let range = block.fullBytes
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { continue }
            for index in range where bytes[index] != 10 { bytes[index] = 0x20 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The size a `.fixedLayout(width:height:)` trait asks for, if the preview has one.
    public var fixedSize: (width: Double, height: Double)? {
        guard let traits = job.block.traits else { return nil }
        let pattern = #"\.fixedLayout\(\s*width:\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*height:\s*([0-9]+(?:\.[0-9]+)?)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: traits, range: NSRange(traits.startIndex..., in: traits)),
              let width = Range(match.range(at: 1), in: traits).flatMap({ Double(traits[$0]) }),
              let height = Range(match.range(at: 2), in: traits).flatMap({ Double(traits[$0]) })
        else { return nil }
        return (width, height)
    }

    // MARK: Helpers

    static func importedModule(of statement: String) -> String? {
        var words = statement.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first.hasPrefix("@") { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { return nil }
        var module = words[1]
        // `import struct Foo.Bar`, `import Foo.Bar`: the module is the first component.
        if ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"].contains(module), words.count >= 3 {
            module = words[2]
        }
        return module.split(separator: ".").first.map(String.init)
    }

    static func escaped(_ string: String) -> String {
        var result = ""
        for character in string {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            default: result.append(character)
            }
        }
        return result
    }

    static func text(of bytes: Range<Int>, in source: String) -> String {
        let utf8 = Array(source.utf8)
        guard bytes.lowerBound >= 0, bytes.upperBound <= utf8.count, bytes.lowerBound <= bytes.upperBound else { return "" }
        return String(decoding: utf8[bytes], as: UTF8.self)
    }

    /// 1-based line of a UTF-8 offset.
    static func line(ofByte byte: Int, in source: String) -> Int {
        var line = 1
        var index = 0
        for value in source.utf8 {
            if index >= byte { break }
            if value == 10 { line += 1 }
            index += 1
        }
        return line
    }
}
