import EditorIntelligence
import Foundation

/// Call Hierarchy for a decompiled `.class` tab: callers and callees read from the bytecode of the
/// jar (or class directory) the class belongs to. There is no project or index behind such a tab, so
/// the source-based ``JavaCallHierarchyProvider`` has nothing to search; every other file still goes
/// to it.
///
/// Callers are methods whose bytecode calls, reads, writes or instantiates the item, found by
/// scanning every class of the container (see ``JavaBytecodeCallerSearch``). They are approximate in
/// the ways bytecode is: a call through a super type is attributed to overrides, reflection and
/// `invokedynamic` targets other than method references are not seen.
public final class JavaBytecodeCallHierarchyProvider: CallHierarchyProviding, @unchecked Sendable {
    private struct Node: Sendable {
        let target: JavaBytecodeTarget
        let container: JavaClassContainer
    }

    private let fallback: any CallHierarchyProviding
    private let cacheRoot: URL
    private let lock = NSLock()
    private var archives: [URL] = []
    private var hierarchyCache: (stamp: String, value: JavaBytecodeHierarchy)?

    public init(fallback: any CallHierarchyProviding, cacheRoot: URL) {
        self.fallback = fallback
        self.cacheRoot = cacheRoot
    }

    /// The jars the user has open, which a class copied out of one is matched against.
    public func setArchives(_ urls: [URL]) {
        lock.withLock { archives = urls }
    }

    /// Unsaved buffers for the source index behind ``fallback``; bytecode reads need none.
    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) async {
        if let fallback = fallback as? JavaCallHierarchyProvider {
            await fallback.setOpenBufferLookup(lookup)
        }
    }

    // MARK: - CallHierarchyProviding

    public func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        if let fileURL, JavaClassFileDecompiler.isClassFile(fileURL), let root = classRoot(source: source, fileURL: fileURL, offset: utf16Offset) {
            return item(for: root, path: nil)
        }
        return await fallback.rootItem(source: source, fileURL: fileURL, utf16Offset: utf16Offset)
    }

    public func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        await callers(of: item, file: file, scope: .all)
    }

    public func callers(of item: HierarchyItem, file: URL?, scope: HierarchyScope) async -> [HierarchyItem] {
        guard let node = item.payload as? Node else { return await fallback.callers(of: item, file: file, scope: scope) }
        let hierarchy = hierarchy(for: node.container)
        let found = await runDetached(priority: .userInitiated) {
            JavaBytecodeCallerSearch.callers(of: node.target, in: node.container, index: hierarchy)
        }
        return found.map { self.item(for: Node(target: $0, container: node.container), path: item.id) }
    }

    public func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let node = item.payload as? Node else { return await fallback.callees(of: item, file: file) }
        guard node.target.kind == .method else { return [] }
        let found = await runDetached(priority: .userInitiated) {
            JavaBytecodeCallerSearch.callees(of: node.target, in: node.container)
        }
        return found.map { self.item(for: Node(target: $0, container: node.container), path: item.id) }
    }

    public func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        guard let node = item.payload as? Node else { return await fallback.location(of: item, file: file) }
        let owner = node.target.owner
        let entry = node.container.entry(forInternalName: owner)
        guard let data = node.container.data(for: entry) else { return nil }
        let url: URL
        switch node.container {
        case .archive(let archive):
            guard let extracted = JavaAttachedSources.extractResource(entry: entry, from: archive, cacheRoot: cacheRoot) else { return nil }
            url = extracted
        case .directory(let root):
            url = root.appendingPathComponent(entry)
        }
        // The text the tab will show is this same decompilation, so ranges taken from it line up.
        // The user has already agreed to decompile: they are looking at a decompiled class.
        let container = node.container
        let target = node.target
        let range = await Task.detached(priority: .userInitiated) { () -> EditorIntelligence.TextRange? in
            guard let text = JavaClassFileDecompiler.decompile(data) else { return nil }
            let locator = JavaBytecodeSymbolLocator(source: text, thisName: owner, container: container)
            guard let bytes = locator.nameRange(of: target) else { return nil }
            return JavaNavigationText.textRange(for: bytes, in: text)
        }.value
        let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return HierarchyLocation(url: url, range: range ?? TextRange(start: start, end: start))
    }

    // MARK: - Roots

    private func classRoot(source: String, fileURL: URL, offset: Int) -> Node? {
        let known = lock.withLock { archives }
        let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard let data, let parsed = JavaBytecodeReader.parse(data, includeBodies: false),
              let container = JavaClassContainer.container(forClassFile: fileURL, archives: known, classData: data) else { return nil }
        let locator = JavaBytecodeSymbolLocator(source: source, thisName: parsed.name, container: container)
        return locator.target(atUTF16Offset: offset).map { Node(target: $0, container: container) }
    }

    // MARK: - Items

    private func item(for node: Node, path: String?) -> HierarchyItem {
        let target = node.target
        let key = "\(target.owner)#\(target.name)\(target.descriptor)"
        let simple = JavaBytecodeDescriptor.displayName(ofInternalName: target.owner)
        let name: String
        switch target.kind {
        case .type:
            name = simple
        case .field:
            name = "\(simple).\(target.name)"
        case .method:
            let parameters = JavaBytecodeDescriptor.parameterKeys(target.descriptor).joined(separator: ", ")
            switch target.name {
            case "<init>": name = "\(simple)(\(parameters))"
            case "<clinit>": name = "\(simple).<static init>"
            default: name = "\(simple).\(target.name)(\(parameters))"
            }
        }
        let inContainer = node.container.contains(internalName: target.owner)
        let isRuntime = ["java/", "javax/", "jdk/", "sun/", "com/sun/"].contains { target.owner.hasPrefix($0) }
        return HierarchyItem(
            id: path.map { $0 + " > " + key } ?? key,
            name: name,
            detail: JavaBytecodeDescriptor.package(ofInternalName: target.owner),
            kind: target.kind == .type ? .classType : .method,
            origin: !inContainer && isRuntime ? .runtime : .library,
            badge: inContainer ? nil : (isRuntime ? "JDK" : "jar"),
            payload: node
        )
    }

    private func hierarchy(for container: JavaClassContainer) -> JavaBytecodeHierarchy {
        let stamp = container.stamp
        if let cached = lock.withLock({ hierarchyCache }), cached.stamp == stamp { return cached.value }
        let built = JavaBytecodeHierarchy.build(container: container)
        lock.withLock { hierarchyCache = (stamp, built) }
        return built
    }
}
