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

    /// What the preview host runs on.
    public enum Platform: Sendable, Equatable {
        /// A macOS process (an AppKit host, `NSHostingView`).
        case macOS
        /// An app in the iOS Simulator (a UIKit host in a bundle, `UIHostingController`), started
        /// and reached through `simctl`; the project is built against the simulator SDK.
        case iOSSimulator
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
        /// `14.0`: the OS version the thunks and the host are compiled for: macOS's, or for the
        /// simulator the runtime's (at least what the project's objects were built for).
        public var deploymentTarget: String
        public var architecture: String
        public var buildSystem: BuildSystem
        /// Leave out the last modifier of the preview body when it is a fixed `.frame(width:height:)`,
        /// so the size the preview is shown at (a device, a window) is not overridden by it. The
        /// file is not changed; only the thunk's copy of the body is.
        public var dropsOuterFrame: Bool
        public var platform: Platform
        /// `-sdk` of every swiftc call for the simulator (`xcrun --sdk iphonesimulator --show-sdk-path`).
        public var sdkPath: String?

        public init(
            packageRoot: String, scratchPath: String, workDirectory: String, targetName: String,
            sourcePath: String, sourceText: String, imports: [String], block: SwiftPreviewBlock,
            deploymentTarget: String = "14.0", architecture: String = "arm64", buildSystem: BuildSystem = .swiftPM,
            dropsOuterFrame: Bool = false, platform: Platform = .macOS, sdkPath: String? = nil
        ) {
            self.platform = platform
            self.sdkPath = sdkPath
            self.dropsOuterFrame = dropsOuterFrame
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

    /// The target triple of every swiftc command: macOS's, or the simulator's.
    public var targetTriple: String {
        switch job.platform {
        case .macOS: return "\(job.architecture)-apple-macos\(job.deploymentTarget)"
        case .iOSSimulator: return "\(job.architecture)-apple-ios\(job.deploymentTarget)-simulator"
        }
    }

    /// `-sdk <path>`: the default SDK of swiftc is macOS's, which a simulator target cannot use.
    var sdkArguments: [String] {
        job.platform == .iOSSimulator ? job.sdkPath.map { ["-sdk", $0] } ?? [] : []
    }

    /// The module whose view type the thunk hands to the host.
    var uiModule: String { job.platform == .macOS ? "AppKit" : "UIKit" }

    // MARK: Paths

    public var hostSourcePath: String { job.workDirectory + "/host/" + SwiftPreviewHostSource.fileName }

    public func thunkSourcePath(generation: Int) -> String { job.workDirectory + "/thunks/Thunk\(generation).swift" }

    public func thunkLibraryPath(generation: Int) -> String { job.workDirectory + "/thunks/libThunk\(generation).dylib" }

    public func framePath(generation: Int) -> String { job.workDirectory + "/frames/frame\(generation).png" }

    public var socketPath: String { job.workDirectory + "/host.sock" }

    /// The shared module, per version of its source, so a changed source never meets an old dylib.
    public var supportDirectory: String {
        job.workDirectory + "/support-v\(SwiftPreviewSupportSource.version)" + (job.platform == .macOS ? "" : "-ios")
    }

    /// The simulator host's app bundle (`UmbraPreviewHost.app`); nil for macOS, where the host is a bare executable.
    public var hostBundlePath: String? {
        job.platform == .iOSSimulator ? job.workDirectory + "/host-ios/UmbraPreviewHost.app" : nil
    }

    /// The bundle identifier of the simulator host: one per work directory, so two projects'
    /// hosts live side by side and a rerun replaces only its own.
    public var hostBundleIdentifier: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in job.workDirectory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hex = String(hash, radix: 16)
        return "com.umbra.preview." + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The executable the host is linked to. Beside the objects for macOS, so `Bundle.module` finds
    /// the resource bundles; inside the app bundle for the simulator.
    public func hostExecutablePath(binPath: String) -> String {
        (hostBundlePath ?? binPath) + "/UmbraPreviewHost"
    }

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
            // only (a fat build would leave two of every object), unsigned. Always the SDK of the
            // host's platform, never the project's own: an object built for `iphoneos` links into
            // neither a macOS process nor a simulator one (an app template's default is `iphoneos`).
            return SwiftPreviewCommand(tool: .xcodebuild, arguments: [
                "-project", project, "-target", job.targetName, "-configuration", "Debug",
                "-sdk", job.platform == .macOS ? "macosx" : "iphonesimulator",
                "SYMROOT=" + job.scratchPath + "/Products", "OBJROOT=" + job.scratchPath + "/Intermediates",
                "ARCHS=" + job.architecture, "ONLY_ACTIVE_ARCH=YES", "ENABLE_TESTABILITY=YES",
                "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
                "OTHER_SWIFT_FLAGS=$(inherited) -enable-testing -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports",
                "build"
            ])
        }
    }

    /// Prints the Xcode target's own build settings (`PLATFORM_NAME = iphoneos`,
    /// `IPHONEOS_DEPLOYMENT_TARGET = 18.0`), to choose the host's platform and to explain a build
    /// that failed. No `-sdk`: the target's own SDK is what is asked about.
    public static func buildSettingsCommand(project: String, target: String) -> SwiftPreviewCommand {
        SwiftPreviewCommand(tool: .xcodebuild, arguments: [
            "-project", project, "-target", target, "-configuration", "Debug", "-showBuildSettings"
        ])
    }

    /// ``buildSettingsCommand(project:target:)`` for this job; nil for SwiftPM.
    public var platformCommand: SwiftPreviewCommand? {
        guard case .xcode(let project) = job.buildSystem else { return nil }
        return Self.buildSettingsCommand(project: project, target: job.targetName)
    }

    /// One setting of `xcodebuild -showBuildSettings` output, by name.
    public static func buildSetting(_ name: String, fromBuildSettings output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(name) else { continue }
            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == name, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    /// The `PLATFORM_NAME` of `xcodebuild -showBuildSettings` output (`iphoneos`, `macosx`…).
    public static func platformName(fromBuildSettings output: String) -> String? {
        buildSetting("PLATFORM_NAME", fromBuildSettings: output)
    }

    /// Where an Xcode build leaves its products, known without asking; nil for SwiftPM.
    public var knownBinPath: String? {
        if case .xcode = job.buildSystem {
            return job.scratchPath + "/Products/" + (job.platform == .macOS ? "Debug" : "Debug-iphonesimulator")
        }
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
            "-target", targetTriple] + sdkArguments + ["-swift-version", "5",
            "-Xfrontend", "-enable-implicit-dynamic",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libUmbraPreviewSupport.dylib",
            "-o", supportLibraryPath, supportSourcePath
        ])
    }

    /// The host, linked with the objects of the project. They are linked whole, so every type the
    /// thunks name is in the process, and the host sits next to them so `Bundle.module` finds the
    /// resource bundles.
    public func hostCommand(binPath: String, objects: [String], modulePaths: [String] = []) -> SwiftPreviewCommand {
        var arguments = ["-target", targetTriple] + sdkArguments + [
            "-swift-version", "5",
            "-I", binPath, "-L", binPath,
            "-I", supportDirectory, "-L", supportDirectory, "-lUmbraPreviewSupport",
            "-Xlinker", "-rpath", "-Xlinker", binPath,
            "-Xlinker", "-rpath", "-Xlinker", supportDirectory,
            "-o", hostExecutablePath(binPath: binPath), hostSourcePath
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
        var arguments = ["-emit-library", "-module-name", "UmbraPreviewThunk\(generation)", "-target", targetTriple]
            + sdkArguments + [
                "-swift-version", "5", "-I", binPath, "-F", binPath, "-I", supportDirectory
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

    public var hostSource: String {
        job.platform == .macOS ? SwiftPreviewHostSource.text : SwiftPreviewIOSHostSource.text
    }

    /// The simulator host's `Info.plist`; nil for macOS.
    public var hostInfoPlist: String? {
        job.platform == .iOSSimulator
            ? SwiftPreviewIOSHostSource.infoPlist(bundleIdentifier: hostBundleIdentifier, minimumOSVersion: job.deploymentTarget)
            : nil
    }

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
        lines.append("import \(uiModule)")
        lines.append("import \(SwiftPreviewSupportSource.moduleName)")
        if mode == .imported {
            for statement in job.imports where Self.importedModule(of: statement) != moduleName {
                guard let module = Self.importedModule(of: statement),
                      !["SwiftUI", uiModule, SwiftPreviewSupportSource.moduleName].contains(module) else { continue }
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
            var text = Self.text(of: job.block.contentBytes, in: job.sourceText)
            if job.dropsOuterFrame, let frame = Self.outerFixedFrame(in: text) {
                // Blanked, not removed: the lines and columns after it stay where the file has them.
                text.replaceSubrange(frame.range, with: String(repeating: " ", count: text[frame.range].count))
            }
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
        switch job.platform {
        case .macOS:
            lines.append("        let view = NSHostingView(rootView: AnyView(UmbraPreviewRoot()))")
            lines.append("        view.sizingOptions = []")
            lines.append("        return Unmanaged.passRetained(view as NSView).toOpaque()")
        case .iOSSimulator:
            // A view controller: the host's window takes it as its root, so safe areas, the
            // navigation bar's large title and the keyboard guide are the system's own.
            lines.append("        let controller = UIHostingController(rootView: AnyView(UmbraPreviewRoot()))")
            lines.append("        return Unmanaged.passRetained(controller as UIViewController).toOpaque()")
        }
        lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The fixed `.frame(width:height:)` that ends a preview body, as `.frame(width: 1100, height: 720)`,
    /// or nil. Only the last modifier of the last expression counts, and only numeric `width:`,
    /// `height:` and `alignment:` arguments: `minWidth`, `maxWidth: .infinity`, an inner frame and a
    /// frame followed by another modifier are the view's own layout and are left alone.
    static func outerFixedFrame(in body: String) -> (range: Range<String.Index>, text: String)? {
        var end = body.endIndex
        while end > body.startIndex, body[body.index(before: end)].isWhitespace { end = body.index(before: end) }
        guard end > body.startIndex, body[body.index(before: end)] == ")" else { return nil }
        // The matching "(": count parentheses backwards. Numbers and labels hold none.
        var depth = 0
        var index = end
        var open: String.Index?
        while index > body.startIndex {
            index = body.index(before: index)
            let character = body[index]
            if character == ")" { depth += 1 }
            if character == "(" {
                depth -= 1
                if depth == 0 {
                    open = index
                    break
                }
            }
        }
        guard let open else { return nil }
        let prefix = ".frame"
        guard let nameStart = body.index(open, offsetBy: -prefix.count, limitedBy: body.startIndex),
              body[nameStart..<open] == prefix else { return nil }
        let arguments = String(body[body.index(after: open)..<body.index(before: end)])
        let number = #"[0-9]+(?:\.[0-9]+)?"#
        let alignment = #"\.?[A-Za-z]+"#
        let argument = #"(?:(?:width|height):\s*\#(number)|alignment:\s*\#(alignment))"#
        let pattern = #"^\s*\#(argument)(?:\s*,\s*\#(argument))*\s*$"#
        guard arguments.range(of: pattern, options: .regularExpression) != nil,
              arguments.contains("width:") || arguments.contains("height:") else { return nil }
        // `alignment:` takes no part in the check above beyond its shape; a repeated label is not valid Swift anyway.
        let range = nameStart..<end
        return (range, String(body[range]))
    }

    /// The fixed frame of `block`'s body in `source`, as written; nil when there is none.
    public static func outerFixedFrame(of block: SwiftPreviewBlock, in source: String) -> String? {
        guard block.kind == .macro else { return nil }
        return outerFixedFrame(in: text(of: block.contentBytes, in: source))?.text
    }

    /// The frame the thunk leaves out, as written; nil when none is dropped.
    public var droppedFrame: String? {
        guard job.dropsOuterFrame else { return nil }
        return Self.outerFixedFrame(of: job.block, in: job.sourceText)
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
