import Foundation

/// A method, field or class named by its bytecode identity.
public struct JavaBytecodeTarget: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case method, field, type }
    public let kind: Kind
    /// Internal name of the declaring class (`a/b/Outer$Inner`).
    public let owner: String
    /// Empty for a type.
    public let name: String
    public let descriptor: String

    public init(kind: Kind, owner: String, name: String = "", descriptor: String = "") {
        self.kind = kind
        self.owner = owner
        self.name = name
        self.descriptor = descriptor
    }
}

/// Who refers to a target, read from the bytecode of every class of a ``JavaClassContainer``.
///
/// A call is `invokevirtual Owner.name:descriptor` where `Owner` is the receiver's static type, so a
/// method is searched under its declaring class, every subclass in the container, and a super type
/// that declares the same method (a call through it can reach this override). A lambda's body is a
/// synthetic `lambda$m$0`; it is reported as `m`.
public enum JavaBytecodeCallerSearch {
    /// Methods (or, for ``JavaBytecodeTarget/Kind/type`` and fields, the same) that refer to `target`.
    /// Only methods that declare code appear, once each, sorted by class and name.
    public static func callers(
        of target: JavaBytecodeTarget, in container: JavaClassContainer, index: JavaBytecodeHierarchy? = nil
    ) -> [JavaBytecodeTarget] {
        let entries = container.classEntries()
        let hierarchy = index ?? JavaBytecodeHierarchy.build(container: container, entries: entries)
        let owners = hierarchy.owners(reaching: target)
        var result: Set<JavaBytecodeTarget> = []
        for entry in entries {
            if Task.isCancelled { break }
            guard let data = container.data(for: entry),
                  let parsed = JavaBytecodeReader.parse(data, includeBodies: true) else { continue }
            // A class using itself (and its nested classes) is not a user of it.
            if target.kind == .type, parsed.name == target.owner || parsed.name.hasPrefix(target.owner + "$") { continue }
            for (offset, method) in parsed.methods.enumerated() where offset < parsed.references.count {
                guard parsed.references[offset].contains(where: { matches($0, target, owners: owners) }) else { continue }
                for caller in attributing(method, in: parsed) {
                    result.insert(JavaBytecodeTarget(
                        kind: .method, owner: parsed.name, name: caller.name, descriptor: caller.descriptor
                    ))
                }
            }
        }
        return result.sorted {
            ($0.owner, $0.name, $0.descriptor) < ($1.owner, $1.name, $1.descriptor)
        }
    }

    /// What `method` (declared in `owner`) refers to: the methods it calls, deduplicated, in order.
    public static func callees(of method: JavaBytecodeTarget, in container: JavaClassContainer) -> [JavaBytecodeTarget] {
        guard let data = container.data(for: container.entry(forInternalName: method.owner)),
              let parsed = JavaBytecodeReader.parse(data, includeBodies: true) else { return [] }
        var seen = Set<JavaBytecodeTarget>()
        var result: [JavaBytecodeTarget] = []
        for (offset, candidate) in parsed.methods.enumerated() where offset < parsed.references.count {
            // The lambdas written inside `method` run as part of it.
            guard attributing(candidate, in: parsed).contains(where: { $0.name == method.name && $0.descriptor == method.descriptor })
            else { continue }
            for reference in parsed.references[offset] {
                guard case .method(let owner, let name, let descriptor) = reference else { continue }
                if owner == method.owner, name.hasPrefix("lambda$") { continue }
                let target = JavaBytecodeTarget(kind: .method, owner: owner, name: name, descriptor: descriptor)
                if seen.insert(target).inserted { result.append(target) }
            }
        }
        return result
    }

    // MARK: - Matching

    private static func matches(
        _ reference: JavaBytecodeReference, _ target: JavaBytecodeTarget, owners: Set<String>
    ) -> Bool {
        switch (target.kind, reference) {
        case (.method, .method(let owner, let name, let descriptor)):
            return name == target.name && descriptor == target.descriptor && owners.contains(owner)
        case (.field, .field(let owner, let name, let descriptor, _)):
            return name == target.name && descriptor == target.descriptor && owners.contains(owner)
        case (.type, .type(let owner)), (.type, .method(let owner, _, _)), (.type, .field(let owner, _, _, _)):
            return owners.contains(owner)
        default:
            return false
        }
    }

    // MARK: - Lambdas

    /// The source-level methods a bytecode method stands for: itself, or for a `lambda$name$n` body the
    /// methods of that class called `name` (`new` is the constructor, `static` the initializer).
    static func attributing(_ method: JavaBytecodeClass.Member, in parsed: JavaBytecodeClass) -> [JavaBytecodeClass.Member] {
        guard method.name.hasPrefix("lambda$") else { return [method] }
        var name = method.name
        while name.hasPrefix("lambda$") {
            name.removeFirst("lambda$".count)
            if let dollar = name.lastIndex(of: "$"), name[name.index(after: dollar)...].allSatisfy(\.isNumber) {
                name = String(name[..<dollar])
            }
        }
        let wanted = name == "new" ? "<init>" : name == "static" ? "<clinit>" : name
        let matches = parsed.methods.filter { $0.name == wanted && !$0.isSynthetic }
        return matches.isEmpty ? [method] : matches
    }
}

/// Super types and declared methods of every class of a container, built from headers alone (no
/// method bodies are read), so asking who can be called through a type is cheap to repeat.
public struct JavaBytecodeHierarchy: Sendable {
    struct Node: Sendable {
        var supers: [String]
        var declared: Set<String>
    }
    private(set) var nodes: [String: Node] = [:]
    private var subtypes: [String: [String]] = [:]

    public static func build(container: JavaClassContainer, entries: [String]? = nil) -> JavaBytecodeHierarchy {
        var hierarchy = JavaBytecodeHierarchy()
        for entry in entries ?? container.classEntries() {
            if Task.isCancelled { break }
            guard let data = container.data(for: entry),
                  let parsed = JavaBytecodeReader.parse(data, includeBodies: false) else { continue }
            let supers = (parsed.superName.map { [$0] } ?? []) + parsed.interfaces
            hierarchy.nodes[parsed.name] = Node(
                supers: supers, declared: Set(parsed.methods.map { $0.name + $0.descriptor })
            )
            for parent in supers { hierarchy.subtypes[parent, default: []].append(parsed.name) }
        }
        return hierarchy
    }

    /// Every class below `name` in the container, `name` included.
    func downward(from name: String) -> Set<String> {
        var seen: Set<String> = [name]
        var pending = [name]
        while let current = pending.popLast() {
            for child in subtypes[current] ?? [] where seen.insert(child).inserted { pending.append(child) }
        }
        return seen
    }

    func upward(from name: String) -> Set<String> {
        var seen: Set<String> = []
        var pending = nodes[name]?.supers ?? []
        while let current = pending.popLast() {
            guard seen.insert(current).inserted else { continue }
            pending.append(contentsOf: nodes[current]?.supers ?? [])
        }
        return seen
    }

    /// The owner names a reference to `target` may carry.
    func owners(reaching target: JavaBytecodeTarget) -> Set<String> {
        var result = downward(from: target.owner)
        switch target.kind {
        case .type, .field:
            break
        case .method:
            let key = target.name + target.descriptor
            // Static methods and constructors are not overridden.
            guard target.name != "<init>", target.name != "<clinit>" else { break }
            // A call through a super type can reach this override: the ancestors that declare the
            // method, the ones between them and this class, and ancestors outside the container
            // (`Runnable.run`). Siblings are not included.
            let ancestors = upward(from: target.owner)
            let declaring = ancestors.filter { nodes[$0]?.declared.contains(key) == true }
            for ancestor in ancestors {
                guard let node = nodes[ancestor] else {
                    result.insert(ancestor)
                    continue
                }
                if node.declared.contains(key) || !upward(from: ancestor).isDisjoint(with: declaring) {
                    result.insert(ancestor)
                }
            }
        }
        return result
    }
}
