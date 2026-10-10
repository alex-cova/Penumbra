import Foundation
import JavaIntelligence

/// What a SwiftPM package declares: its targets, products and package dependencies.
///
/// Two sources fill it. `parse(source:)` reads `Package.swift` with the Swift grammar and needs
/// nothing run, so opening a folder never executes it; it sees a manifest written as literals and
/// misses one that builds its target list with code. `parse(dumpPackage:)` reads the JSON of
/// `swift package dump-package`, which evaluates the manifest and is therefore exact, and is only
/// asked for after the user trusts the folder.
struct IDESwiftPMManifest: Sendable, Equatable {
    enum TargetKind: String, Sendable {
        case regular, executable, test, macro, plugin, system, binary

        var isCode: Bool { self != .system && self != .binary }
    }

    struct Target: Sendable, Equatable {
        var name: String
        var kind: TargetKind
        /// The `path:` argument, relative to the package.
        var path: String?
        /// Names of the targets and products it depends on, as written.
        var dependencies: [String]
    }

    struct Product: Sendable, Equatable {
        var name: String
        var isExecutable: Bool
        var targets: [String]
    }

    struct PackageDependency: Sendable, Equatable {
        var name: String
        var location: String
        var isLocal: Bool
    }

    var name: String
    var targets: [Target] = []
    var products: [Product] = []
    var packages: [PackageDependency] = []
    /// Read from `dump-package`: the manifest was evaluated.
    var isExact = false

    var dependencyCount: Int { packages.count }

    /// What `swift run` can start: executable products, and executable targets (SwiftPM makes a
    /// product of each).
    var executableNames: [String] {
        var names: [String] = []
        for product in products where product.isExecutable && !names.contains(product.name) { names.append(product.name) }
        for target in targets where target.kind == .executable && !names.contains(target.name) { names.append(target.name) }
        return names
    }

    var hasTests: Bool { targets.contains { $0.kind == .test } }

    func target(named name: String) -> Target? {
        targets.first { $0.name == name }
    }

    /// The directory holding a target's sources: its `path:`, else the conventional folder that
    /// exists, else `Sources/<name>` (`Tests/<name>` for a test target).
    func directory(of target: Target, root: URL) -> URL {
        if let path = target.path, !path.isEmpty {
            return root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
        }
        let parents = target.kind == .test ? ["Tests", "Test"] : ["Sources", "Source", "src", "srcs"]
        let fileManager = FileManager.default
        for parent in parents {
            let candidate = root.appendingPathComponent(parent, isDirectory: true)
                .appendingPathComponent(target.name, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return root.appendingPathComponent(parents[0], isDirectory: true)
            .appendingPathComponent(target.name, isDirectory: true).standardizedFileURL
    }

    /// The module a file belongs to: the target whose directory is the longest prefix of its path.
    func moduleResolver(root: URL) -> @Sendable (URL) -> String? {
        let directories = targets.filter(\.kind.isCode).map { target -> (prefix: String, name: String) in
            (directory(of: target, root: root).path + "/", target.name)
        }.sorted { $0.prefix.count > $1.prefix.count }
        return { url in
            let path = url.standardizedFileURL.path
            return directories.first { path.hasPrefix($0.prefix) }?.name
        }
    }

    // MARK: Package.swift

    /// The manifest as written, or nil when no `Package(…)` call is found.
    static func parse(source: String, folderName: String) -> IDESwiftPMManifest? {
        guard let parsed = SwiftAnalysis.parse(source), let package = findPackageCall(in: parsed.tree.rootNode) else { return nil }
        var manifest = IDESwiftPMManifest(name: folderName)
        for argument in arguments(of: package) {
            switch argument.label {
            case "name":
                if let value = string(argument.value) { manifest.name = value }
            case "products":
                for element in elements(of: argument.value) {
                    guard let call = callNode(element), let kind = calleeName(call) else { continue }
                    let args = arguments(of: call)
                    guard let name = args.first(where: { $0.label == "name" }).flatMap({ string($0.value) }) else { continue }
                    let targets = args.first { $0.label == "targets" }.map { elements(of: $0.value).compactMap(string) } ?? []
                    manifest.products.append(Product(name: name, isExecutable: kind == "executable", targets: targets))
                }
            case "dependencies":
                for element in elements(of: argument.value) {
                    guard let call = callNode(element), calleeName(call) == "package" else { continue }
                    if let dependency = packageDependency(from: arguments(of: call)) { manifest.packages.append(dependency) }
                }
            case "targets":
                for element in elements(of: argument.value) {
                    guard let call = callNode(element), let kindName = calleeName(call),
                          let kind = targetKind(named: kindName) else { continue }
                    let args = arguments(of: call)
                    guard let name = args.first(where: { $0.label == "name" }).flatMap({ string($0.value) }) else { continue }
                    var dependencies: [String] = []
                    if let list = args.first(where: { $0.label == "dependencies" }) {
                        for item in elements(of: list.value) {
                            if let plain = string(item) {
                                dependencies.append(plain)
                            } else if let call = callNode(item),
                                      let named = arguments(of: call).first(where: { $0.label == "name" || $0.label == nil })
                                          .flatMap({ string($0.value) }) {
                                dependencies.append(named)
                            }
                        }
                    }
                    manifest.targets.append(Target(
                        name: name, kind: kind, path: args.first { $0.label == "path" }.flatMap { string($0.value) },
                        dependencies: dependencies
                    ))
                }
            default:
                break
            }
        }
        return manifest
    }

    private static func targetKind(named name: String) -> TargetKind? {
        switch name {
        case "target": return .regular
        case "executableTarget": return .executable
        case "testTarget": return .test
        case "macro": return .macro
        case "plugin": return .plugin
        case "systemLibrary": return .system
        case "binaryTarget": return .binary
        default: return nil
        }
    }

    private static func packageDependency(from args: [(label: String?, value: SyntaxNode)]) -> PackageDependency? {
        if let url = args.first(where: { $0.label == "url" }).flatMap({ string($0.value) }) {
            let last = url.split(separator: "/").last.map(String.init) ?? url
            let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
            return PackageDependency(name: name, location: url, isLocal: false)
        }
        if let path = args.first(where: { $0.label == "path" }).flatMap({ string($0.value) }) {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return PackageDependency(name: name, location: path, isLocal: true)
        }
        return nil
    }

    // MARK: Syntax helpers

    private static func findPackageCall(in root: SyntaxNode) -> SyntaxNode? {
        var pending = [root]
        var visited = 0
        while let node = pending.popLast(), visited < 20_000 {
            visited += 1
            if node.type == "call_expression", let callee = node.namedChild(at: 0),
               callee.type == "simple_identifier", callee.text == "Package" {
                return node
            }
            node.enumerateChildren { child, _ in
                if child.isNamed, child.type != "comment" { pending.append(child) }
            }
        }
        return nil
    }

    private static func arguments(of call: SyntaxNode) -> [(label: String?, value: SyntaxNode)] {
        var result: [(label: String?, value: SyntaxNode)] = []
        call.enumerateChildren { suffix, _ in
            guard suffix.type == "call_suffix" else { return }
            suffix.enumerateChildren { list, _ in
                guard list.type == "value_arguments" else { return }
                list.enumerateChildren { argument, _ in
                    guard argument.type == "value_argument", let value = argument.child(byFieldName: "value") else { return }
                    let label = argument.child(byFieldName: "name").map { $0.namedChildren.first?.text ?? $0.text }
                    result.append((label, value))
                }
            }
        }
        return result
    }

    /// `.target(…)`, `Target.target(…)`, `.package(…)`: the name after the last dot.
    private static func calleeName(_ call: SyntaxNode) -> String? {
        guard let callee = call.namedChild(at: 0) else { return nil }
        switch callee.type {
        case "simple_identifier":
            return callee.text
        case "prefix_expression":
            return callee.child(byFieldName: "target")?.text
        case "navigation_expression":
            return callee.child(byFieldName: "suffix")?.child(byFieldName: "suffix")?.text
        default:
            return nil
        }
    }

    private static func callNode(_ node: SyntaxNode) -> SyntaxNode? {
        node.type == "call_expression" ? node : nil
    }

    private static func elements(of node: SyntaxNode) -> [SyntaxNode] {
        guard node.type == "array_literal" else { return [] }
        var result: [SyntaxNode] = []
        node.enumerateChildren { child, field in
            if field == "element" { result.append(child) }
        }
        return result
    }

    /// The text of a plain string literal; nil for anything with an interpolation or another kind of value.
    private static func string(_ node: SyntaxNode) -> String? {
        guard node.type == "line_string_literal" || node.type == "multi_line_string_literal" else { return nil }
        var text = ""
        var hasInterpolation = false
        node.enumerateChildren { child, _ in
            if child.type == "line_str_text" || child.type == "multi_line_str_text" {
                text += child.text
            } else if child.type == "interpolated_expression" {
                hasInterpolation = true
            }
        }
        return hasInterpolation ? nil : text
    }

    // MARK: dump-package

    /// The JSON `swift package dump-package` prints. Tolerant of the shapes SwiftPM versions use.
    static func parse(dumpPackage data: Data, folderName: String) -> IDESwiftPMManifest? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var manifest = IDESwiftPMManifest(name: (object["name"] as? String) ?? folderName)
        manifest.isExact = true
        for case let target as [String: Any] in object["targets"] as? [Any] ?? [] {
            guard let name = target["name"] as? String else { continue }
            let kind = TargetKind(rawValue: (target["type"] as? String) ?? "regular") ?? .regular
            var dependencies: [String] = []
            for case let dependency as [String: Any] in target["dependencies"] as? [Any] ?? [] {
                for key in ["byName", "product", "target"] {
                    if let values = dependency[key] as? [Any], let first = values.first as? String {
                        dependencies.append(first)
                    }
                }
            }
            manifest.targets.append(Target(name: name, kind: kind, path: target["path"] as? String, dependencies: dependencies))
        }
        for case let product as [String: Any] in object["products"] as? [Any] ?? [] {
            guard let name = product["name"] as? String else { continue }
            var isExecutable = false
            if let type = product["type"] as? [String: Any] { isExecutable = type["executable"] != nil }
            if let type = product["type"] as? String { isExecutable = type == "executable" }
            manifest.products.append(Product(
                name: name, isExecutable: isExecutable, targets: product["targets"] as? [String] ?? []
            ))
        }
        for case let dependency as [String: Any] in object["dependencies"] as? [Any] ?? [] {
            for kind in ["sourceControl", "fileSystem", "registry"] {
                guard let entries = dependency[kind] as? [Any] else { continue }
                for case let entry as [String: Any] in entries {
                    let identity = (entry["identity"] as? String) ?? (entry["name"] as? String) ?? ""
                    var location = ""
                    var isLocal = kind == "fileSystem"
                    if let path = entry["path"] as? String {
                        location = path
                    } else if let place = entry["location"] as? [String: Any] {
                        if let remote = place["remote"] as? [Any] {
                            let first = remote.first
                            location = (first as? [String: Any])?["urlString"] as? String ?? (first as? String) ?? ""
                        } else if let local = place["local"] as? [Any], let path = local.first as? String {
                            location = path
                            isLocal = true
                        }
                    }
                    if !identity.isEmpty { manifest.packages.append(PackageDependency(name: identity, location: location, isLocal: isLocal)) }
                }
            }
        }
        return manifest
    }
}
