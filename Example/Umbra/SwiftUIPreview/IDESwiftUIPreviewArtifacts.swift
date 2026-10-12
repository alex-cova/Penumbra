import Foundation

/// Where a package build left what the host has to be linked with.
///
/// A library target leaves one merged object (`<Module>.o`) and its `.swiftmodule` beside the
/// products with Swift 6.4's build engine. An executable target leaves only the linked program
/// there: its per-file objects and its `.swiftmodule` are in the intermediates, and the object of
/// the file with `@main` defines `main`, which would collide with the host's. Older SwiftPM
/// layouts keep per-module `<Module>.build` directories and a `Modules` directory.
enum IDESwiftUIPreviewArtifacts {
    struct Located: Equatable {
        /// Every object to link, the ones that may define `main` included.
        var objects: [String]
        /// Directories to search for `.swiftmodule`s (`-I`), in addition to the bin path.
        var modulePaths: [String]
    }

    static func locate(binPath: String, module: String, fileManager: FileManager = .default) -> Located {
        let bin = URL(fileURLWithPath: binPath)
        func contents(_ directory: URL, suffix: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(suffix) }.sorted().map { directory.appendingPathComponent($0).path }
        }
        func directories(in directory: URL, suffix: String) -> [URL] {
            ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(suffix) }.sorted().map { directory.appendingPathComponent($0, isDirectory: true) }
        }

        var objects = contents(bin, suffix: ".o")
        var modulePaths: [String] = []

        // Swift 6.4's engine: `<scratch>/out/Products/<Config>` beside `<scratch>/out/Intermediates.noindex`.
        let out = bin.deletingLastPathComponent().deletingLastPathComponent()
        let configuration = bin.lastPathComponent
        let intermediates = out.appendingPathComponent("Intermediates.noindex", isDirectory: true)
        let moduleBuild = intermediates
            .appendingPathComponent("\(module).build", isDirectory: true)
            .appendingPathComponent(configuration, isDirectory: true)
        if fileManager.fileExists(atPath: moduleBuild.path) {
            for unit in directories(in: moduleBuild, suffix: ".build") {
                let arm = unit.appendingPathComponent("Objects-normal", isDirectory: true)
                for architecture in directories(in: arm, suffix: "") {
                    if fileManager.fileExists(atPath: architecture.appendingPathComponent("\(module).swiftmodule").path) {
                        modulePaths.append(architecture.path)
                    }
                    // The merged object of a library is already in the bin directory; the program's is not.
                    if !objects.contains(where: { $0.hasSuffix("/\(module).o") }) {
                        objects += contents(architecture, suffix: ".o").filter { !$0.hasSuffix("_lto.o") }
                    }
                }
            }
        }

        // Older layout: `<bin>/<Module>.build/*.o` per module and `<bin>/Modules`.
        if objects.isEmpty {
            for build in directories(in: bin, suffix: ".build") { objects += contents(build, suffix: ".o") }
            let modules = bin.appendingPathComponent("Modules", isDirectory: true)
            if fileManager.fileExists(atPath: modules.path) { modulePaths.append(modules.path) }
        }
        return Located(objects: objects, modulePaths: modulePaths)
    }

    /// An Xcode build's objects: every `Objects-normal/<arch>/*.o` under its intermediates, the
    /// targets it built for dependencies included. The module is beside the products.
    static func locateXcode(intermediates: String, architecture: String, fileManager: FileManager = .default) -> [String] {
        var objects: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: intermediates) else { return objects }
        for case let relative as String in enumerator {
            guard relative.hasSuffix(".o"), !relative.hasSuffix("_lto.o"),
                  relative.contains("/Objects-normal/\(architecture)/") else { continue }
            objects.append(intermediates + "/" + relative)
        }
        return objects.sorted()
    }

    /// The files `nm -gU` reported a defined `_main` for. `nm` prints `path:` before each file's
    /// symbols when it is given several, and no header for one.
    static func objectsDefiningMain(nmOutput: String, files: [String]) -> Set<String> {
        var result: Set<String> = []
        var current: String? = files.count == 1 ? files[0] : nil
        for line in nmOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasSuffix(":"), !text.contains(" ") || files.contains(String(text.dropLast())) {
                current = String(text.dropLast())
                continue
            }
            let parts = text.split(separator: " ")
            if parts.count >= 3, parts[1] == "T", parts[2] == "_main", let current { result.insert(current) }
        }
        return result
    }
}
