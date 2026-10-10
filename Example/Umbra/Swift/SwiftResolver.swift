import EditorIntelligence
import Foundation

/// Types names and chains of one file against that file's model and the project index.
///
/// A value's type is what the text says. Unknown stays unknown: nothing is guessed through
/// generics, overload resolution or the standard library, because a wrong answer here becomes a
/// wrong rename.
struct SwiftResolver: Sendable {
    enum Value: Sendable, Equatable {
        case instance(String)
        case metatype(String)
        /// A function: the type applying it gives (`nil` when unknown or `Void`) and the type it was found on.
        case callable(returns: String?, receiver: String?)
        case module(String)
    }

    /// What a name refers to.
    enum Target: Sendable {
        case binding(SwiftFileModel.Binding)
        case declaration(url: URL?, declaration: SwiftFileModel.Declaration, owner: String?)
        case module(String)

        /// A stable identity across files: where the declaration's name is written.
        var identity: String? {
            switch self {
            case .binding(let binding):
                return "binding:\(binding.nameBytes.lowerBound):\(binding.name)"
            case .declaration(let url, let declaration, _):
                return Self.declarationIdentity(url: url, nameBytes: declaration.nameBytes, name: declaration.name)
            case .module(let name):
                return "module:\(name)"
            }
        }

        static func declarationIdentity(url: URL?, nameBytes: Range<Int>, name: String) -> String {
            "decl:\(url?.standardizedFileURL.path ?? ""):\(nameBytes.lowerBound):\(name)"
        }
    }

    let index: SwiftIndex
    let model: SwiftFileModel
    let url: URL?

    private static let maxDepth = 8

    // MARK: Chains

    func value(of chain: SwiftChain, at byte: Int, expected: String? = nil, depth: Int = 0) async -> Value? {
        guard depth < Self.maxDepth else { return nil }
        guard var current = await baseValue(chain.base, at: byte, expected: expected, depth: depth) else { return nil }
        for step in chain.steps {
            guard let next = await apply(step, to: current, at: byte, depth: depth) else { return nil }
            current = next
        }
        return current
    }

    /// The type name of an instance value, if the chain has one.
    func typeName(of chain: SwiftChain, at byte: Int, expected: String? = nil) async -> String? {
        guard let value = await value(of: chain, at: byte, expected: expected) else { return nil }
        if case .instance(let name) = value { return name }
        return nil
    }

    private func baseValue(_ base: SwiftChain.Base, at byte: Int, expected: String?, depth: Int) async -> Value? {
        switch base {
        case .unknown:
            return nil
        case .instance(let name):
            return .instance(name)
        case .metatype(let name):
            return .metatype(name)
        case .selfValue:
            return enclosingTypeName(at: byte).map { .instance($0) }
        case .superValue:
            return await superclassName(at: byte).map { .instance($0) }
        case .implicitMember(let name):
            guard let expected else { return nil }
            return await memberValue(named: name, onType: expected, isMetatype: true, depth: depth)
        case .name(let name, let at):
            return await nameValue(name, at: at, depth: depth)
        }
    }

    private func nameValue(_ name: String, at byte: Int, depth: Int) async -> Value? {
        if let binding = model.binding(named: name, at: byte) {
            switch binding.symbolKind {
            case .type:
                return .metatype(binding.typeName ?? name)
            case .function:
                return .callable(returns: binding.typeName, receiver: nil)
            case .parameter, .local:
                if let typeName = binding.typeName { return .instance(typeName) }
                guard let source = binding.source else { return nil }
                guard let value = await self.value(of: source, at: binding.scopeStart, depth: depth + 1) else { return nil }
                if binding.sourceIsElement {
                    if case .instance(let collection) = value, let element = SwiftTypeNames.elementType(of: collection) {
                        return .instance(element)
                    }
                    return nil
                }
                return value
            }
        }
        for type in model.enclosingTypes(at: byte).reversed() {
            if let value = await memberValue(named: name, onType: type.name, isMetatype: false, depth: depth) {
                return value
            }
        }
        for declaration in model.topLevelDeclarations(named: name) {
            if let value = await value(of: declaration, owner: nil, in: self, depth: depth) { return value }
        }
        for ref in await index.topLevel(named: name, visibleFrom: url) {
            if let value = await valueOfDeclaration(ref.declaration, in: ref.url, owner: nil, depth: depth) { return value }
        }
        if !(await index.types(named: name, visibleFrom: url)).isEmpty || typeDeclaredInFile(name) {
            return .metatype(name)
        }
        if model.imports.contains(where: { $0.module == name }) { return .module(name) }
        if let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
            return .metatype(name)
        }
        return nil
    }

    private func apply(_ step: SwiftChain.Step, to value: Value, at byte: Int, depth: Int) async -> Value? {
        switch (step, value) {
        case (.unwrap, _):
            return value
        case (.member(let name), .instance(let type)):
            let receiver = SwiftTypeNames.unwrappedOptional(type)
            if let found = await memberValue(named: name, onType: receiver, isMetatype: false, depth: depth) { return found }
            return SwiftStandardLibrary.memberValue(named: name, onType: receiver)
        case (.member(let name), .metatype(let type)):
            if name == "init" { return .callable(returns: type, receiver: type) }
            if name == "self" { return .metatype(type) }
            return await memberValue(named: name, onType: type, isMetatype: true, depth: depth)
        case (.member(let name), .module(let module)):
            for ref in await index.types(named: name, visibleFrom: url) where ref.module == nil || ref.module == module {
                return .metatype(name)
            }
            for ref in await index.topLevel(named: name, visibleFrom: url) where ref.module == nil || ref.module == module {
                if let found = await valueOfDeclaration(ref.declaration, in: ref.url, owner: nil, depth: depth) { return found }
            }
            if let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) { return .metatype(name) }
            return nil
        case (.member, .callable):
            return nil
        case (.call, .metatype(let type)):
            return .instance(type)
        case (.call, .callable(let returns, let receiver)):
            guard let returns, returns != "Void", returns != "()" else { return nil }
            return .instance(returns == "Self" ? (receiver ?? returns) : returns)
        case (.call, .instance), (.call, .module):
            return nil
        case (.subscripted, .instance(let type)):
            return SwiftTypeNames.elementType(of: type).map { .instance($0) }
        case (.subscripted, _):
            return nil
        }
    }

    // MARK: Callees

    /// The functions and initializers a callee chain can refer to, every overload: the last step's
    /// name looked up on what comes before it, or a bare name looked up in scope.
    func callees(of chain: SwiftChain, at byte: Int) async -> [(declaration: SwiftFileModel.Declaration, owner: String?)] {
        var result: [(SwiftFileModel.Declaration, String?)] = []
        func functionLike(_ declaration: SwiftFileModel.Declaration) -> Bool {
            declaration.kind == .function || declaration.kind == .initializer || declaration.kind == .enumCase
        }
        if let last = chain.steps.last, case .member(let name) = last {
            let receiver = SwiftChain(base: chain.base, steps: Array(chain.steps.dropLast()))
            guard let value = await self.value(of: receiver, at: byte) else { return [] }
            switch value {
            case .instance(let type), .metatype(let type):
                for ref in await index.members(ofType: SwiftTypeNames.unwrappedOptional(type), visibleFrom: url)
                where ref.declaration.name == name && functionLike(ref.declaration) {
                    result.append((ref.declaration, ref.owner))
                }
                if name == "init" {
                    for ref in await index.members(ofType: type, visibleFrom: url) where ref.declaration.kind == .initializer {
                        result.append((ref.declaration, ref.owner))
                    }
                }
            default:
                break
            }
            return result
        }
        guard chain.steps.isEmpty, case .name(let name, let at) = chain.base else { return [] }
        for type in model.enclosingTypes(at: at).reversed() {
            for ref in await index.members(ofType: type.name, visibleFrom: url)
            where ref.declaration.name == name && functionLike(ref.declaration) {
                result.append((ref.declaration, ref.owner))
            }
        }
        for declaration in model.topLevelDeclarations(named: name) where functionLike(declaration) {
            result.append((declaration, nil))
        }
        for ref in await index.topLevel(named: name, visibleFrom: url) where functionLike(ref.declaration) {
            result.append((ref.declaration, nil))
        }
        if result.isEmpty {
            for ref in await index.members(ofType: name, visibleFrom: url) where ref.declaration.kind == .initializer {
                result.append((ref.declaration, name))
            }
        }
        return result
    }

    // MARK: Members

    /// A member `name` of `type` as a value, found through the index (extensions and inheritance included).
    func memberValue(named name: String, onType type: String, isMetatype: Bool, depth: Int) async -> Value? {
        let type = SwiftTypeNames.unwrappedOptional(type)
        let members = await index.members(ofType: type, visibleFrom: url)
        let named = members.filter { $0.declaration.name == name }
        let preferred = named.first { ref in
            let isStatic = ref.declaration.isStatic || ref.declaration.kind == .enumCase
            return isStatic == isMetatype
        } ?? named.first
        if let ref = preferred {
            return await valueOfDeclaration(ref.declaration, in: ref.url, owner: ref.owner, depth: depth)
        }
        for nested in await index.nestedTypes(in: type, visibleFrom: url) where nested.declaration.name == name {
            return .metatype(name)
        }
        return nil
    }

    /// The value a declaration stands for when named.
    private func valueOfDeclaration(
        _ declaration: SwiftFileModel.Declaration, in file: URL?, owner: String?, depth: Int
    ) async -> Value? {
        switch declaration.kind {
        case .property:
            if let typeName = declaration.typeName { return .instance(Self.replacingSelf(typeName, with: owner)) }
            guard let chain = declaration.valueChain, depth < Self.maxDepth else { return nil }
            let resolver = await resolver(for: file)
            guard let value = await resolver.value(of: chain, at: declaration.fullBytes.lowerBound, depth: depth + 1) else {
                return nil
            }
            return value
        case .function:
            return .callable(returns: declaration.typeName.map { Self.replacingSelf($0, with: owner) }, receiver: owner)
        case .initializer:
            return .callable(returns: owner, receiver: owner)
        case .enumCase:
            return declaration.parameters.isEmpty
                ? owner.map { .instance($0) }
                : .callable(returns: owner, receiver: owner)
        case .class, .struct, .enum, .actor, .protocol, .typeAlias, .associatedType:
            return .metatype(declaration.name)
        case .extension, .deinitializer, .subscript:
            return nil
        }
    }

    private func value(
        of declaration: SwiftFileModel.Declaration, owner: String?, in resolver: SwiftResolver, depth: Int
    ) async -> Value? {
        await valueOfDeclaration(declaration, in: url, owner: owner, depth: depth)
    }

    private func resolver(for file: URL?) async -> SwiftResolver {
        guard let file, file.standardizedFileURL != url?.standardizedFileURL,
              let other = await index.model(for: file) else { return self }
        return SwiftResolver(index: index, model: other, url: file)
    }

    static func replacingSelf(_ typeName: String, with owner: String?) -> String {
        guard typeName == "Self", let owner else { return typeName }
        return owner
    }

    // MARK: Context

    /// The innermost type or extension containing `byte`, by the name members are looked up under.
    func enclosingTypeName(at byte: Int) -> String? {
        model.enclosingTypes(at: byte).last?.name
    }

    func superclassName(at byte: Int) async -> String? {
        guard let type = model.enclosingTypes(at: byte).last else { return nil }
        let candidates = type.inherits + (await index.supertypes(of: type.name, visibleFrom: url))
        for name in candidates {
            for ref in await index.types(named: name, visibleFrom: url) where ref.declaration.kind == .class {
                return name
            }
        }
        return candidates.first
    }

    private func typeDeclaredInFile(_ name: String) -> Bool {
        func visit(_ declarations: [SwiftFileModel.Declaration]) -> Bool {
            for declaration in declarations {
                if declaration.kind.isTypeLike, declaration.name == name { return true }
                if (declaration.kind.isNominalType || declaration.kind == .extension), visit(declaration.members) { return true }
            }
            return false
        }
        return visit(model.declarations)
    }

    // MARK: Targets

    /// What the name written at `bytes` refers to. `expected` types a leading-dot member.
    func target(forNameAt bytes: Range<Int>, expected: String? = nil) async -> Target? {
        if let binding = model.binding(atNameBytes: bytes) { return .binding(binding) }
        if let declaration = model.declaration(atNameBytes: bytes) {
            let owner = model.enclosingTypes(at: bytes.lowerBound).last?.name
            return .declaration(url: url, declaration: declaration, owner: declaration.isTopLevel ? nil : owner)
        }
        guard let use = model.use(at: bytes) else { return nil }
        let labels = use.isCall ? use.callLabels : nil
        switch use.role {
        case .type:
            if let binding = model.binding(named: use.name, at: use.bytes.lowerBound), binding.symbolKind == .type {
                return .binding(binding)
            }
            if let found = await typeTarget(named: use.name) { return found }
            if model.imports.contains(where: { $0.module == use.name }) { return .module(use.name) }
            return nil
        case .value:
            if let binding = model.binding(named: use.name, at: use.bytes.lowerBound) { return .binding(binding) }
            for type in model.enclosingTypes(at: use.bytes.lowerBound).reversed() {
                if let found = await memberTarget(named: use.name, onType: type.name, isMetatype: nil, labels: labels) {
                    return found
                }
            }
            let tops = model.topLevelDeclarations(named: use.name).map {
                TargetCandidate(url: url, declaration: $0, owner: nil)
            } + (await index.topLevel(named: use.name, visibleFrom: url).map {
                TargetCandidate(url: $0.url, declaration: $0.declaration, owner: nil)
            })
            if let pick = Self.pick(tops, labels: labels) {
                return .declaration(url: pick.url, declaration: pick.declaration, owner: nil)
            }
            if let found = await typeTarget(named: use.name) { return found }
            if model.imports.contains(where: { $0.module == use.name }) { return .module(use.name) }
            return nil
        case .member(let chain):
            guard let receiver = await value(of: chain, at: use.bytes.lowerBound, expected: expected) else { return nil }
            switch receiver {
            case .instance(let type):
                return await memberTarget(
                    named: use.name, onType: SwiftTypeNames.unwrappedOptional(type), isMetatype: false, labels: labels
                )
            case .metatype(let type):
                return await memberTarget(named: use.name, onType: type, isMetatype: true, labels: labels)
            case .module(let module):
                if let found = await typeTarget(named: use.name, module: module) { return found }
                return nil
            case .callable:
                return nil
            }
        case .implicitMember:
            guard let expected else { return nil }
            return await memberTarget(named: use.name, onType: expected, isMetatype: true, labels: labels)
        }
    }

    private struct TargetCandidate {
        var url: URL?
        var declaration: SwiftFileModel.Declaration
        var owner: String?
    }

    /// Several declarations share a name: the one whose parameter labels are the call's.
    private static func pick(_ candidates: [TargetCandidate], labels: [String]?) -> TargetCandidate? {
        guard let first = candidates.first else { return nil }
        guard let labels else { return first }
        let exact = candidates.first { candidate in
            candidate.declaration.parameters.map { $0.label ?? "_" } == labels
        }
        if let exact { return exact }
        let counted = candidates.first { candidate in
            let parameters = candidate.declaration.parameters
            let required = parameters.filter { !$0.hasDefault }.count
            return labels.count >= required && labels.count <= parameters.count
        }
        return counted ?? first
    }

    private func memberTarget(named name: String, onType type: String, isMetatype: Bool?, labels: [String]?) async -> Target? {
        let members = await index.members(ofType: type, visibleFrom: url)
        var candidates = members.filter { $0.declaration.name == name }.map {
            TargetCandidate(url: $0.url, declaration: $0.declaration, owner: $0.owner)
        }
        if candidates.isEmpty, name == "init" || labels != nil, let isMetatype, isMetatype {
            candidates = members.filter { $0.declaration.kind == .initializer }.map {
                TargetCandidate(url: $0.url, declaration: $0.declaration, owner: $0.owner)
            }
        }
        if let isMetatype, candidates.count > 1 {
            let matching = candidates.filter { ($0.declaration.isStatic || $0.declaration.kind == .enumCase) == isMetatype }
            if !matching.isEmpty { candidates = matching }
        }
        if let pick = Self.pick(candidates, labels: labels) {
            return .declaration(url: pick.url, declaration: pick.declaration, owner: pick.owner)
        }
        for nested in await index.nestedTypes(in: type, visibleFrom: url) where nested.declaration.name == name {
            return .declaration(url: nested.url, declaration: nested.declaration, owner: type)
        }
        return nil
    }

    /// A type named `name`: the file's own declaration, else the best the index has.
    private func typeTarget(named name: String, module: String? = nil) async -> Target? {
        var found: [(url: URL?, declaration: SwiftFileModel.Declaration)] = []
        func collect(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations {
                if declaration.kind.isTypeLike, declaration.name == name { found.append((url, declaration)) }
                if declaration.kind.isNominalType || declaration.kind == .extension { collect(declaration.members) }
            }
        }
        if module == nil { collect(model.declarations) }
        if let first = found.first { return .declaration(url: first.url, declaration: first.declaration, owner: nil) }
        let refs = await index.types(named: name, visibleFrom: url).filter { module == nil || $0.module == nil || $0.module == module }
        guard let ref = refs.first(where: { $0.declaration.kind != .typeAlias }) ?? refs.first else { return nil }
        return .declaration(url: ref.url, declaration: ref.declaration, owner: nil)
    }
}

/// Type names as `SwiftFileModel` writes them: `[Int]`, `[String: Int]`, `Foo`.
enum SwiftTypeNames {
    static func unwrappedOptional(_ name: String) -> String {
        var name = name
        while name.hasSuffix("?") || name.hasSuffix("!") { name.removeLast() }
        return name
    }

    /// The element of `[E]`, the value of `[K: V]`.
    static func elementType(of name: String) -> String? {
        let name = unwrappedOptional(name)
        guard name.hasPrefix("["), name.hasSuffix("]") else { return nil }
        let inner = String(name.dropFirst().dropLast())
        var depth = 0
        var previous: Character = " "
        for (offset, character) in inner.enumerated() {
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            if depth == 0, character == " ", previous == ":" {
                let value = String(inner.dropFirst(offset + 1))
                return value == "?" ? nil : value
            }
            previous = character
        }
        return inner == "?" ? nil : inner
    }

    static func isCollection(_ name: String) -> Bool {
        let name = unwrappedOptional(name)
        return name.hasPrefix("[") && name.hasSuffix("]")
    }
}
