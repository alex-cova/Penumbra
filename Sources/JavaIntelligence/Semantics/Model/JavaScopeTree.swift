import Foundation

/// The lexical scope tree of one parse (JLS 6.3): every scope that declares a name, built once
/// per parse and attached to it (`JavaSyntaxTree.scopeTree(for:)`), instead of re-walked per
/// query like `JavaLocalScope.locals(in:atByteOffset:)`.
///
/// Each declaration carries the UTF-8 byte range it is visible in, so queries are range checks,
/// not tree walks. Shadowing resolves innermost-first; a name redeclared in an inner scope hides
/// the outer one.
///
/// Deliberate differences from `JavaLocalScope` (all JLS-closer, all pinned by tests):
/// - a local is visible in its own initializer (`int x = x` names `x`; `javac` reports
///   "might not have been initialized", not "cannot find symbol");
/// - a `switch` block is one scope, so a local declared in one group is visible in later ones;
/// - `if`/`while` pattern bindings use polarity (`&&` left-to-right, `||` under negation, `!`
///   flips) and flow out past the statement when the taken branch cannot complete normally
///   (`if (!(o instanceof Foo f)) return; f.…`);
/// - record patterns bind their components (typed from the pattern itself);
/// - multi-catch alternatives are all recorded (`alternativeTypes`; the primary type stays the
///   first until `JavaTypes` computes the lub).
///
/// Out of v1, documented at each site: qualifier resolution (`unknown` in `unknown.Known`),
/// single-static-import names, do-while pattern flow, `var` resources naming an existing
/// variable (correctly: no new binding), and operand-local visibility inside conditions wrapped
/// in an explicit `!` (direct `&&`/`||` chains are covered).
public final class JavaScopeTree: Sendable {
    public struct Declaration: Sendable {
        public let symbol: JavaSymbol
        /// The byte range the name is visible in, from the end of the declaring name.
        public let visibleRange: Range<Int>
        public let initializerText: String?
        public let lambdaOrigin: JavaLambdaOrigin?
        public let isIterationVariable: Bool
        /// Every declared type for a multi-catch parameter; single-element otherwise.
        public let alternativeTypes: [JavaTypeRef]

        public init(
            symbol: JavaSymbol, visibleRange: Range<Int>, initializerText: String? = nil,
            lambdaOrigin: JavaLambdaOrigin? = nil, isIterationVariable: Bool = false,
            alternativeTypes: [JavaTypeRef] = []
        ) {
            self.symbol = symbol
            self.visibleRange = visibleRange
            self.initializerText = initializerText
            self.lambdaOrigin = lambdaOrigin
            self.isIterationVariable = isIterationVariable
            self.alternativeTypes = alternativeTypes
        }
    }

    public struct Scope: Sendable {
        public enum Kind: Sendable {
            case file
            case type(name: String)
            case method(name: String)
            case constructor
            case initializer
            case block
            case forLoop
            case enhancedFor
            case resources
            case catchClause
            case lambda
            case switchBlock
            case switchRule
        }

        public let kind: Kind
        public let range: Range<Int>
        public let declarations: [Declaration]
        public let children: [Scope]
    }

    public let url: URL
    public let root: Scope

    public init(tree: JavaSyntaxTree, url: URL) {
        self.url = url
        self.root = ScopeBuilder(tree: tree, url: url).buildFile()
    }

    // MARK: - Queries

    /// Scopes containing the offset, outermost first.
    public func scopeChain(atByteOffset offset: Int) -> [Scope] {
        var chain: [Scope] = []
        var current: Scope? = root
        while let scope = current, scope.range.contains(offset) {
            chain.append(scope)
            current = scope.children.last { $0.range.contains(offset) }
        }
        return chain
    }

    /// The locals visible at the offset, innermost first, shadowed names dropped: the same
    /// answers as `JavaLocalScope.locals(in:atByteOffset:)` except for the documented deltas.
    public func locals(atByteOffset offset: Int) -> [JavaLocalVariable] {
        var result: [JavaLocalVariable] = []
        var seen = Set<String>()
        for scope in scopeChain(atByteOffset: offset).reversed() {
            for declaration in scope.declarations where declaration.visibleRange.contains(offset) {
                let variable: JavaLocalVariable
                switch declaration.symbol {
                case .local(let name, _, _, let type):
                    variable = JavaLocalVariable(
                        name: name, type: type,
                        initializerText: declaration.initializerText, lambdaOrigin: declaration.lambdaOrigin,
                        isIterationVariable: declaration.isIterationVariable
                    )
                case .parameter(let name, _, _, let type):
                    variable = JavaLocalVariable(name: name, type: type)
                default:
                    continue
                }
                if seen.insert(variable.name).inserted { result.append(variable) }
            }
        }
        return result
    }

    /// The innermost declaration of `name` visible at the offset: locals, parameters, pattern
    /// bindings, types and labels alike.
    public func symbol(named name: String, atByteOffset offset: Int) -> JavaSymbol? {
        for scope in scopeChain(atByteOffset: offset).reversed() {
            for declaration in scope.declarations where declaration.visibleRange.contains(offset) {
                if declaration.symbol.name == name { return declaration.symbol }
            }
        }
        return nil
    }

    /// The innermost scope containing the offset, for tests and debugging.
    public func innermostScope(atByteOffset offset: Int) -> Scope? {
        scopeChain(atByteOffset: offset).last
    }
}

private struct ScopeBuilder {
    let tree: JavaSyntaxTree
    let url: URL
    let packageName: String
    let stubsByName: [String: JavaClassStub]

    init(tree: JavaSyntaxTree, url: URL) {
        self.tree = tree
        self.url = url
        self.packageName = tree.rootNode.namedChildren
            .first { $0.type == "package_declaration" }?
            .child(byFieldName: "name")?.text ?? ""
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        self.stubsByName = Dictionary(
            fileStubs.classes.map { ($0.qualifiedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func qualifiedName(for simpleName: String, enclosing: [String]) -> String {
        ((packageName.isEmpty ? [] : [packageName]) + enclosing + [simpleName]).joined(separator: ".")
    }

    // MARK: - File and types

    func buildFile() -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        var children: [JavaScopeTree.Scope] = []
        for child in tree.rootNode.namedChildren {
            switch child.type {
            case "class_declaration", "interface_declaration", "enum_declaration",
                 "record_declaration", "annotation_type_declaration":
                buildType(child, qualifiedName: qualifiedName(for: typeName(of: child) ?? "", enclosing: []),
                          declarations: &declarations, children: &children)
            default:
                // Imports, package declaration, module directives: no bindings. (Single
                // static imports do name a member, but its stub needs the index; the resolver
                // owns those, not the scope tree.)
                children += expressionScopes(in: child)
            }
        }
        return JavaScopeTree.Scope(kind: .file, range: tree.rootNode.byteRange, declarations: declarations, children: children)
    }

    func typeName(of node: SyntaxNode) -> String? {
        node.child(byFieldName: "name")?.text
    }

    /// Declares a type in the current scope and builds its member scopes as children. Member
    /// types qualify (`Outer.Inner`); types inside bodies have no qualified name and identify
    /// by site (`.localType`).
    func buildType(
        _ node: SyntaxNode, qualifiedName: String,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        guard let nameNode = node.child(byFieldName: "name") else { return }
        let symbol: JavaSymbol
        if qualifiedName.contains(".") || !qualifiedName.isEmpty, let stub = stubsByName[qualifiedName] {
            symbol = .type(stub: stub)
        } else {
            symbol = .localType(name: nameNode.text, file: url, declarationRange: nameNode.byteRange)
        }
        declarations.append(JavaScopeTree.Declaration(
            symbol: symbol, visibleRange: nameNode.byteRange.upperBound..<tree.rootNode.byteRange.upperBound))
        guard let body = node.child(byFieldName: "body") else { return }
        children.append(buildTypeBody(body, qualifiedName: qualifiedName, kind: .type(name: nameNode.text)))
    }

    /// The members of a type body: fields and enum constants declared in the type scope,
    /// member types and executable members as child scopes.
    func buildTypeBody(_ body: SyntaxNode, qualifiedName: String, kind: JavaScopeTree.Scope.Kind) -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        var children: [JavaScopeTree.Scope] = []
        let scopeEnd = body.byteRange.upperBound
        for member in body.namedChildren {
            switch member.type {
            case "field_declaration":
                buildField(member, owner: qualifiedName, scopeEnd: scopeEnd,
                           declarations: &declarations, children: &children)
            case "method_declaration", "constructor_declaration", "compact_constructor_declaration":
                if let methodScope = buildExecutable(member, owner: qualifiedName) { children.append(methodScope) }
            case "class_declaration", "interface_declaration", "enum_declaration",
                 "record_declaration", "annotation_type_declaration":
                let name = typeName(of: member) ?? ""
                buildType(member, qualifiedName: qualifiedName.isEmpty ? name : qualifiedName + "." + name,
                          declarations: &declarations, children: &children)
            case "block":
                // An instance initializer.
                children.append(buildExecutableBody(member, parameters: [], methodName: nil, isConstructor: false,
                                                    owner: qualifiedName, kind: .initializer))
            case "static_initializer":
                children.append(buildExecutableBody(member, parameters: [], methodName: nil, isConstructor: false,
                                                    owner: qualifiedName, kind: .initializer))
            case "enum_body_declarations", "modifiers", ";":
                break
            case "ERROR":
                // Garbled member text: recover whatever member declarations survived inside.
                recoverMembers(in: member, qualifiedName: qualifiedName, scopeEnd: scopeEnd,
                               declarations: &declarations, children: &children)
            default:
                // Enum constants are fields in the file stubs; anything else holds no bindings.
                if member.type == "enum_constant" {
                    buildEnumConstant(member, owner: qualifiedName, scopeEnd: scopeEnd, declarations: &declarations)
                } else {
                    children += expressionScopes(in: member)
                }
            }
        }
        // Methods and constructors also name-bind in the type scope for the future resolver.
        if let stub = stubsByName[qualifiedName] {
            for method in stub.methods where method.isConstructor == false {
                declarations.append(JavaScopeTree.Declaration(
                    symbol: .method(declaringClass: qualifiedName, stub: method),
                    visibleRange: body.byteRange.lowerBound..<scopeEnd))
            }
            for constructor in stub.methods where constructor.isConstructor {
                declarations.append(JavaScopeTree.Declaration(
                    symbol: .constructor(declaringClass: qualifiedName, stub: constructor),
                    visibleRange: body.byteRange.lowerBound..<scopeEnd))
            }
            for field in stub.fields {
                // Fields declared above cover the common case; the stub pass catches whatever
                // the scope walk missed (erroneous trees) without duplicating names.
                if !declarations.contains(where: { $0.symbol.name == field.name }) {
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .field(declaringClass: qualifiedName, stub: field),
                        visibleRange: body.byteRange.lowerBound..<scopeEnd))
                }
            }
        }
        return JavaScopeTree.Scope(kind: kind, range: body.byteRange, declarations: declarations, children: children)
    }

    func buildField(
        _ node: SyntaxNode, owner: String, scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        guard let stub = stubsByName[owner] else {
            children += expressionScopes(in: node)
            return
        }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let nameNode = declarator.child(byFieldName: "name"),
                  let field = stub.fields.first(where: { $0.name == nameNode.text }) else { continue }
            declarations.append(JavaScopeTree.Declaration(
                symbol: .field(declaringClass: owner, stub: field),
                visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
            if let value = declarator.child(byFieldName: "value") {
                children += expressionScopes(in: value)
            }
        }
    }

    func buildEnumConstant(
        _ node: SyntaxNode, owner: String, scopeEnd: Int, declarations: inout [JavaScopeTree.Declaration]
    ) {
        guard let nameNode = node.child(byFieldName: "name"),
              let field = stubsByName[owner]?.fields.first(where: { $0.name == nameNode.text }) else { return }
        declarations.append(JavaScopeTree.Declaration(
            symbol: .field(declaringClass: owner, stub: field),
            visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
    }

    // MARK: - Executables

    func executableName(of node: SyntaxNode) -> String? {
        node.child(byFieldName: "name")?.text
    }

    /// A method, constructor or compact constructor scope, or `nil` when the declaration is too
    /// broken to name. Parameters and type parameters declare in the scope; the body builds
    /// beneath it. An ERROR node where a body should be still yields its parameters.
    func buildExecutable(_ node: SyntaxNode, owner: String) -> JavaScopeTree.Scope? {
        let isConstructor = node.type != "method_declaration"
        let name = isConstructor ? nil : executableName(of: node)
        if node.type == "method_declaration", name == nil { return nil }
        let kind: JavaScopeTree.Scope.Kind = isConstructor ? .constructor : .method(name: name ?? "")
        return buildExecutableBody(node, parameters: executableParameters(of: node, owner: owner, isConstructor: isConstructor),
                                   methodName: name, isConstructor: isConstructor, owner: owner, kind: kind)
    }

    func executableParameters(of node: SyntaxNode, owner: String, isConstructor: Bool) -> [JavaScopeTree.Declaration] {
        guard let parameters = node.child(byFieldName: "parameters") else { return [] }
        var declarations: [JavaScopeTree.Declaration] = []
        let scopeEnd = node.byteRange.upperBound
        for parameter in parameters.namedChildren
            where parameter.type == "formal_parameter" || parameter.type == "spread_parameter" {
            guard let typeNode = parameter.child(byFieldName: "type"),
                  let nameNode = parameter.child(byFieldName: "name") else { continue }
            declarations.append(JavaScopeTree.Declaration(
                symbol: .parameter(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                   type: JavaTypeNodeConverter.convert(typeNode)),
                visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
        }
        return declarations
    }

    func buildExecutableBody(
        _ node: SyntaxNode, parameters: [JavaScopeTree.Declaration], methodName: String?,
        isConstructor: Bool, owner: String, kind: JavaScopeTree.Scope.Kind
    ) -> JavaScopeTree.Scope {
        var declarations = parameters
        var children: [JavaScopeTree.Scope] = []
        // Type parameters bind in the whole declaration.
        if let typeParameters = node.child(byFieldName: "type_parameters") {
            let ownerID: JavaSymbolID?
            if isConstructor {
                ownerID = nil
            } else if let name = methodName {
                ownerID = .method(declaringClass: owner, name: name, parameterKeys: JavaTypeKeys.keys(of: node))
            } else {
                ownerID = nil
            }
            for parameter in typeParameters.namedChildren where parameter.type == "type_parameter" {
                guard let nameNode = parameter.firstNamedChild(ofType: "identifier") ?? parameter.child(byFieldName: "name") else { continue }
                declarations.append(JavaScopeTree.Declaration(
                    symbol: .typeParameter(name: nameNode.text, owner: ownerID),
                    visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound))
            }
        }
        if let body = node.child(byFieldName: "body") {
            buildStatements(body.namedChildren, scopeEnd: body.byteRange.upperBound,
                            declarations: &declarations, children: &children)
        } else {
            // Corrupt body: recover whatever parameters survived inside, like JavaLocalScope.
            for descendant in errorDescendants(of: node) {
                for parameter in descendant.namedChildren where parameter.type == "formal_parameter" {
                    guard let typeNode = parameter.child(byFieldName: "type"),
                          let nameNode = parameter.child(byFieldName: "name") else { continue }
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .parameter(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                           type: JavaTypeNodeConverter.convert(typeNode)),
                        visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound))
                }
            }
        }
        // Compact constructors and odd bodies without a "body" field still nest statements.
        if node.child(byFieldName: "body") == nil {
            for child in node.namedChildren where child.type == "block" {
                children.append(buildBlock(child))
            }
        }
        return JavaScopeTree.Scope(kind: kind, range: node.byteRange, declarations: declarations, children: children)
    }

    func errorDescendants(of node: SyntaxNode) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        var stack = [node]
        while let current = stack.popLast() {
            if current.type == "ERROR" { result.append(current) }
            for index in (0..<current.namedChildCount).reversed() {
                stack.append(current.namedChild(at: index)!)
            }
        }
        return result
    }

    // MARK: - Blocks and statements

    func buildBlock(_ node: SyntaxNode, seeded: [JavaScopeTree.Declaration] = []) -> JavaScopeTree.Scope {
        var declarations = seeded
        var children: [JavaScopeTree.Scope] = []
        buildStatements(node.namedChildren, scopeEnd: node.byteRange.upperBound,
                        declarations: &declarations, children: &children)
        return JavaScopeTree.Scope(kind: .block, range: node.byteRange, declarations: declarations, children: children)
    }

    func buildStatements(
        _ statements: [SyntaxNode], scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        for statement in statements {
            processStatement(statement, scopeEnd: scopeEnd, declarations: &declarations, children: &children)
        }
    }

    func processStatement(
        _ statement: SyntaxNode, scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        // Patterns inside `&&`/`||` chains bind within their own right operands wherever the
        // chain appears; attaching for the whole subtree covers conditions, returns and
        // initializers uniformly.
        attachOperandBindings(in: statement, declarations: &declarations)
        switch statement.type {
        case "local_variable_declaration":
            buildLocalVariables(statement, scopeEnd: scopeEnd, declarations: &declarations, children: &children)
        case "class_declaration", "interface_declaration", "enum_declaration",
             "record_declaration", "annotation_type_declaration":
            let name = typeName(of: statement) ?? ""
            buildType(statement, qualifiedName: name, declarations: &declarations, children: &children)
        case "block":
            children.append(buildBlock(statement))
        case "if_statement":
            buildIf(statement, scopeEnd: scopeEnd, declarations: &declarations, children: &children)
        case "while_statement":
            buildWhile(statement, declarations: &declarations, children: &children)
        case "do_statement":
            if let body = statement.namedChildren.first(where: { $0.type == "block" }) {
                children.append(buildBlock(body))
            } else {
                var branchDecls: [JavaScopeTree.Declaration] = []
                var branchChildren: [JavaScopeTree.Scope] = []
                for child in statement.namedChildren where child.type != "parenthesized_expression" {
                    processStatement(child, scopeEnd: scopeEnd, declarations: &branchDecls, children: &branchChildren)
                }
                children.append(JavaScopeTree.Scope(kind: .block, range: statement.byteRange,
                                                    declarations: branchDecls, children: branchChildren))
            }
            children += expressionScopes(in: statement)
        case "for_statement":
            buildFor(statement, children: &children)
        case "enhanced_for_statement":
            buildEnhancedFor(statement, children: &children)
        case "try_statement", "try_with_resources_statement":
            buildTry(statement, children: &children)
        case "switch_statement", "switch_expression":
            if let block = statement.namedChildren.first(where: { $0.type == "switch_block" }) {
                children.append(buildSwitchBlock(block))
            }
            children += expressionScopes(in: statement)
        case "synchronized_statement":
            if let body = statement.child(byFieldName: "body") {
                children.append(buildBlock(body))
            }
            children += expressionScopes(in: statement)
        case "labeled_statement":
            if let nameNode = statement.namedChildren.first, nameNode.type == "identifier" {
                declarations.append(JavaScopeTree.Declaration(
                    symbol: .label(name: nameNode.text, file: url, declarationRange: nameNode.byteRange),
                    visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
            }
            for child in statement.namedChildren where child.type != "identifier" {
                processStatement(child, scopeEnd: scopeEnd, declarations: &declarations, children: &children)
            }
        case "ERROR":
            // A corrupted statement still yields whatever parameters survived inside it.
            for descendant in errorDescendants(of: statement) {
                for parameter in descendant.namedChildren where parameter.type == "formal_parameter" {
                    guard let typeNode = parameter.child(byFieldName: "type"),
                          let nameNode = parameter.child(byFieldName: "name") else { continue }
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .parameter(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                           type: JavaTypeNodeConverter.convert(typeNode)),
                        visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
                }
            }
            children += expressionScopes(in: statement)
        default:
            children += expressionScopes(in: statement)
        }
    }

    func buildLocalVariables(
        _ node: SyntaxNode, scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        guard let typeNode = node.child(byFieldName: "type") else { return }
        let isVar = typeNode.text == "var"
        let type = JavaTypeNodeConverter.convert(typeNode)
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let nameNode = declarator.child(byFieldName: "name") else { continue }
            let initializer = isVar ? declarator.child(byFieldName: "value")?.text : nil
            declarations.append(JavaScopeTree.Declaration(
                symbol: .local(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                               type: isVar ? .unresolved(simpleName: "var", arguments: []) : type),
                visibleRange: nameNode.byteRange.upperBound..<scopeEnd,
                initializerText: initializer))
            if let value = declarator.child(byFieldName: "value") {
                children += expressionScopes(in: value)
            }
        }
    }

    // MARK: - Branches and flow

    /// A pattern binding found in a condition or case label, before placement.
    struct PendingBinding {
        let name: String
        let nameRange: Range<Int>
        let type: JavaTypeRef
        let alternativeTypes: [JavaTypeRef]
    }

    func declaration(for binding: PendingBinding, visibleRange: Range<Int>) -> JavaScopeTree.Declaration {
        JavaScopeTree.Declaration(
            symbol: .local(name: binding.name, file: url, declarationRange: binding.nameRange, type: binding.type),
            visibleRange: visibleRange, alternativeTypes: binding.alternativeTypes)
    }

    /// The branch of an `if`/`while` condition: a block builds beneath seeds, anything else wraps.
    func buildBranch(_ branch: SyntaxNode?, seeds: [JavaScopeTree.Declaration]) -> JavaScopeTree.Scope? {
        guard let branch else { return nil }
        if branch.type == "block" { return buildBlock(branch, seeded: seeds) }
        var declarations = seeds
        var children: [JavaScopeTree.Scope] = []
        // The seeds stay visible through the whole branch even for a single statement.
        processStatement(branch, scopeEnd: branch.byteRange.upperBound, declarations: &declarations, children: &children)
        return JavaScopeTree.Scope(kind: .block, range: branch.byteRange, declarations: declarations, children: children)
    }

    func buildIf(
        _ node: SyntaxNode, scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        guard let condition = node.child(byFieldName: "condition"),
              let consequence = node.child(byFieldName: "consequence") else {
            children += expressionScopes(in: node)
            return
        }
        let alternative = node.child(byFieldName: "alternative")
        let positive = conditionBindings(in: condition, assumed: true)
        let negative = conditionBindings(in: condition, assumed: false)
        if let thenScope = buildBranch(consequence, seeds: positive.map {
            declaration(for: $0, visibleRange: consequence.byteRange)
        }) { children.append(thenScope) }
        if let alternative, let elseScope = buildBranch(alternative, seeds: negative.map {
            declaration(for: $0, visibleRange: alternative.byteRange)
        }) { children.append(elseScope) }
        children += expressionScopes(in: condition)
        // Flow out: the bindings of the side that cannot run.
        let thenAbrupt = cannotCompleteNormally(consequence)
        let elseAbrupt = alternative.map(cannotCompleteNormally) ?? false
        let afterRange = node.byteRange.upperBound..<scopeEnd
        if alternative == nil {
            if thenAbrupt {
                for binding in negative { declarations.append(declaration(for: binding, visibleRange: afterRange)) }
            }
        } else if thenAbrupt, !elseAbrupt {
            for binding in negative { declarations.append(declaration(for: binding, visibleRange: afterRange)) }
        } else if elseAbrupt, !thenAbrupt {
            for binding in positive { declarations.append(declaration(for: binding, visibleRange: afterRange)) }
        }
    }

    /// Right-operand bindings made visible by a preceding pattern on the same `&&`/`||`
    /// chain (e.g. `s` in `s.length() > 0` after `o instanceof String s && ...`). Runs over a
    /// whole statement subtree, so patterns bind inside `if`/`while` conditions as well as
    /// `return` expressions and initializers. The visible range is the right operand itself:
    /// tight enough to cover the operand but not the rest of the statement. Re-running over
    /// an overlapping subtree adds nothing twice.
    func attachOperandBindings(in node: SyntaxNode, declarations: inout [JavaScopeTree.Declaration]) {
        if node.type == "binary_expression",
           let left = node.child(byFieldName: "left"),
           let right = node.child(byFieldName: "right"),
           let op = operatorText(of: node),
           op == "&&" || op == "||" {
            // `&&` evaluates the right side when the left holds (positive bindings); `||`
            // when it does not (negative bindings: usually empty, which is exactly right).
            for binding in conditionBindings(in: left, assumed: op == "&&") {
                let declaration = declaration(for: binding, visibleRange: right.byteRange)
                if !declarations.contains(where: {
                    $0.symbol.name == declaration.symbol.name && $0.visibleRange == declaration.visibleRange
                }) {
                    declarations.append(declaration)
                }
            }
        }
        // Indexed walk: `children`/`namedChildren` materialize an array per node.
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index) {
                attachOperandBindings(in: child, declarations: &declarations)
            }
        }
    }

    /// The anonymous operator token of a `binary_expression`, without materializing `children`.
    func operatorText(of node: SyntaxNode) -> String? {
        for index in 0..<node.childCount {
            if let child = node.child(at: index), !child.isNamed { return child.text }
        }
        return nil
    }

    func buildWhile(_ node: SyntaxNode, declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]) {
        guard let condition = node.child(byFieldName: "condition"),
              let body = node.child(byFieldName: "body") else {
            children += expressionScopes(in: node)
            return
        }
        let seeds = conditionBindings(in: condition, assumed: true).map {
            declaration(for: $0, visibleRange: body.byteRange)
        }
        if let bodyScope = buildBranch(body, seeds: seeds) { children.append(bodyScope) }
        children += expressionScopes(in: condition)
    }

    /// Whether the statement cannot complete normally (JLS 14.21, structurally): `return` and
    /// `throw`, blocks ending in one, and `if` with both sides abrupt.
    func cannotCompleteNormally(_ node: SyntaxNode) -> Bool {
        switch node.type {
        case "return_statement", "throw_statement":
            return true
        case "block":
            guard let last = node.namedChildren.last else { return false }
            return cannotCompleteNormally(last)
        case "if_statement":
            guard let consequence = node.child(byFieldName: "consequence"),
                  let alternative = node.child(byFieldName: "alternative") else { return false }
            return cannotCompleteNormally(consequence) && cannotCompleteNormally(alternative)
        default:
            return false
        }
    }

    // MARK: - Loops, try, switch

    func buildFor(_ node: SyntaxNode, children: inout [JavaScopeTree.Scope]) {
        var declarations: [JavaScopeTree.Declaration] = []
        if let initializer = node.child(byFieldName: "init"),
           initializer.type == "local_variable_declaration" {
            var nested: [JavaScopeTree.Scope] = []
            buildLocalVariables(initializer, scopeEnd: node.byteRange.upperBound,
                                declarations: &declarations, children: &nested)
            children += nested
        }
        if let body = node.child(byFieldName: "body"),
           let bodyScope = buildBranch(body, seeds: declarations) { children.append(bodyScope) }
        for field in ["condition", "update"] {
            if let part = node.child(byFieldName: field) { children += expressionScopes(in: part) }
        }
    }

    func buildEnhancedFor(_ node: SyntaxNode, children: inout [JavaScopeTree.Scope]) {
        var declarations: [JavaScopeTree.Declaration] = []
        if let nameNode = node.child(byFieldName: "name") {
            if let typeNode = node.child(byFieldName: "type") {
                if typeNode.text == "var", let iterated = node.child(byFieldName: "value") {
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .local(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                       type: .unresolved(simpleName: "var", arguments: [])),
                        visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound,
                        initializerText: iterated.text, isIterationVariable: true))
                } else {
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .local(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                       type: JavaTypeNodeConverter.convert(typeNode)),
                        visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound))
                }
            }
        }
        if let body = node.child(byFieldName: "body"),
           let bodyScope = buildBranch(body, seeds: declarations) { children.append(bodyScope) }
        if let iterated = node.child(byFieldName: "value") { children += expressionScopes(in: iterated) }
    }

    func buildTry(_ node: SyntaxNode, children: inout [JavaScopeTree.Scope]) {
        var resources: [JavaScopeTree.Declaration] = []
        if node.type == "try_with_resources_statement",
           let spec = node.firstNamedChild(ofType: "resource_specification") {
            for resource in spec.namedChildren where resource.type == "resource" {
                guard let nameNode = resource.child(byFieldName: "name") else { continue }
                if let typeNode = resource.child(byFieldName: "type") {
                    resources.append(JavaScopeTree.Declaration(
                        symbol: .local(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                       type: JavaTypeNodeConverter.convert(typeNode)),
                        visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound))
                }
                // A bare name (`try (in)`) binds nothing new: it must be definite already.
            }
        }
        var inner: [JavaScopeTree.Scope] = []
        for child in node.namedChildren {
            switch child.type {
            case "block":
                inner.append(buildBlock(child))
            case "catch_clause":
                inner.append(buildCatch(child))
            case "finally_clause":
                for grandchild in child.namedChildren {
                    if grandchild.type == "block" { inner.append(buildBlock(grandchild)) }
                    else { inner += expressionScopes(in: grandchild) }
                }
            default:
                inner += expressionScopes(in: child)
            }
        }
        // Resource variables scope over the body, the catches and the finally (JLS 6.3), so
        // those nest inside the resources scope instead of beside it.
        if resources.isEmpty {
            children += inner
        } else {
            children.append(JavaScopeTree.Scope(kind: .resources, range: node.byteRange,
                                                declarations: resources, children: inner))
        }
    }

    func buildCatch(_ node: SyntaxNode) -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        if let parameter = node.firstNamedChild(ofType: "catch_formal_parameter"),
           let nameNode = parameter.child(byFieldName: "name") {
            let alternatives = parameter.firstNamedChild(ofType: "catch_type")?.namedChildren
                .map { JavaTypeNodeConverter.convert($0) } ?? []
            let primary = alternatives.first ?? .unresolved(simpleName: "Throwable", arguments: [])
            declarations.append(JavaScopeTree.Declaration(
                symbol: .parameter(name: nameNode.text, file: url, declarationRange: nameNode.byteRange, type: primary),
                visibleRange: nameNode.byteRange.upperBound..<node.byteRange.upperBound,
                alternativeTypes: alternatives))
        }
        var children: [JavaScopeTree.Scope] = []
        if let body = node.child(byFieldName: "body") {
            children.append(buildBlock(body, seeded: declarations))
            declarations = []
        }
        return JavaScopeTree.Scope(kind: .catchClause, range: node.byteRange, declarations: declarations, children: children)
    }

    /// One scope for the whole `switch_block`: groups share it (JLS 6.3), rules nest beneath it.
    func buildSwitchBlock(_ block: SyntaxNode) -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        var children: [JavaScopeTree.Scope] = []
        let scopeEnd = block.byteRange.upperBound
        for child in block.namedChildren {
            switch child.type {
            case "switch_block_statement_group":
                buildStatements(child.namedChildren, scopeEnd: scopeEnd,
                                declarations: &declarations, children: &children)
            case "switch_rule":
                children.append(buildSwitchRule(child))
            default:
                children += expressionScopes(in: child)
            }
        }
        return JavaScopeTree.Scope(kind: .switchBlock, range: block.byteRange,
                                   declarations: declarations, children: children)
    }

    func buildSwitchRule(_ rule: SyntaxNode) -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        var children: [JavaScopeTree.Scope] = []
        for child in rule.namedChildren {
            declarations += patternBindings(in: child).map {
                declaration(for: $0, visibleRange: rule.byteRange)
            }
            if child.type == "block" {
                children.append(buildBlock(child, seeded: declarations))
                declarations = []
            }
        }
        // Guards and arrow expressions see the rule patterns; collect their instanceof
        // bindings too (positive: the guard passed).
        for child in rule.namedChildren where child.type != "block" {
            for binding in conditionBindings(in: child, assumed: true) {
                declarations.append(declaration(for: binding, visibleRange: rule.byteRange))
            }
        }
        for child in rule.namedChildren where child.type != "block" {
            children += expressionScopes(in: child)
        }
        return JavaScopeTree.Scope(kind: .switchRule, range: rule.byteRange,
                                   declarations: declarations, children: children)
    }

    // MARK: - Conditions and patterns

    /// Bindings that hold when `node` evaluates to `assumed`: `&&` flows left-to-right, `||`
    /// flows under negation, `!` flips, parentheses are transparent.
    func conditionBindings(in node: SyntaxNode, assumed: Bool) -> [PendingBinding] {
        switch node.type {
        case "parenthesized_expression":
            return node.namedChildren.flatMap { conditionBindings(in: $0, assumed: assumed) }
        case "unary_expression" where node.child(at: 0)?.type == "!":
            // `!` is an anonymous token, not a named child: the operands are all named children.
            return node.namedChildren.flatMap { conditionBindings(in: $0, assumed: !assumed) }
        case "binary_expression":
            guard let left = node.child(byFieldName: "left"),
                  let right = node.child(byFieldName: "right"),
                  let op = node.children.first(where: { !$0.isNamed })?.text else { return [] }
            if op == "&&" {
                // The right side runs when the left is true.
                return conditionBindings(in: left, assumed: assumed)
                    + (assumed ? conditionBindings(in: right, assumed: true) : [])
            } else if op == "||" {
                // The right side runs when the left is false.
                return conditionBindings(in: left, assumed: assumed)
                    + (assumed ? [] : conditionBindings(in: right, assumed: false))
            }
            return []
        case "instanceof_expression":
            guard assumed else { return [] }
            return patternBindings(in: node)
        default:
            return []
        }
    }

    /// Bindings of one pattern: a type pattern binds its name; a record pattern decomposes
    /// (typed from the pattern itself, so no index is needed); anything else binds nothing.
    func patternBindings(in node: SyntaxNode) -> [PendingBinding] {
        if node.type == "type_pattern" {
            guard let nameNode = node.child(byFieldName: "name"),
                  let typeNode = node.child(byFieldName: "type") ?? node.child(byFieldName: "right") else { return [] }
            return [PendingBinding(name: nameNode.text, nameRange: nameNode.byteRange,
                                   type: JavaTypeNodeConverter.convert(typeNode), alternativeTypes: [])]
        }
        if node.type == "instanceof_expression" {
            // A nested pattern (`record_pattern`, ...) rides under `pattern:`; a plain type
            // pattern carries `name:` directly.
            if let pattern = node.child(byFieldName: "pattern") { return patternBindings(in: pattern) }
            guard let nameNode = node.child(byFieldName: "name"),
                  let typeNode = node.child(byFieldName: "type") ?? node.child(byFieldName: "right") else { return [] }
            return [PendingBinding(name: nameNode.text, nameRange: nameNode.byteRange,
                                   type: JavaTypeNodeConverter.convert(typeNode), alternativeTypes: [])]
        }
        if node.type == "record_pattern" {
            return node.namedChildren.flatMap { patternBindings(in: $0) }
                .filter { $0.name != "_" }
        }
        if node.type == "record_pattern_body" {
            return node.namedChildren.flatMap { patternBindings(in: $0) }
                .filter { $0.name != "_" }
        }
        if node.type == "record_pattern_component" {
            // A nested pattern decomposes on its own; otherwise `(Type) (name)` binds the name
            // typed from the pattern itself. `_` binds nothing.
            let nested = node.namedChildren.flatMap { patternBindings(in: $0) }
            if !nested.isEmpty { return nested }
            guard let nameNode = node.namedChildren.first(where: { $0.type == "identifier" }),
                  nameNode.text != "_",
                  let typeNode = node.namedChildren.first(where: { $0.type != "identifier" })
            else { return [] }
            return [PendingBinding(name: nameNode.text, nameRange: nameNode.byteRange,
                                   type: JavaTypeNodeConverter.convert(typeNode), alternativeTypes: [])]
        }
        return []
    }

    // MARK: - Expression scopes

    /// Scopes for lambdas and anonymous classes anywhere inside an expression or statement:
    /// their bodies nest, everything else holds no bindings.
    func expressionScopes(in node: SyntaxNode) -> [JavaScopeTree.Scope] {
        var scopes: [JavaScopeTree.Scope] = []
        var stack = [node]
        while let current = stack.popLast() {
            if current.type == "lambda_expression" {
                scopes.append(buildLambda(current))
                continue
            }
            if current.type == "object_creation_expression",
               let body = current.namedChildren.first(where: { $0.type == "class_body" }) {
                scopes.append(buildTypeBody(body, qualifiedName: "", kind: .type(name: "")))
                continue
            }
            for index in (0..<current.namedChildCount).reversed() {
                stack.append(current.namedChild(at: index)!)
            }
        }
        return scopes
    }

    /// Member declarations recovered from inside a corrupt (`ERROR`) body region: nested
    /// types still nest, executable signatures still yield their scopes, plain fields still bind.
    func recoverMembers(
        in node: SyntaxNode, qualifiedName: String, scopeEnd: Int,
        declarations: inout [JavaScopeTree.Declaration], children: inout [JavaScopeTree.Scope]
    ) {
        var stack = node.namedChildren
        while let current = stack.popLast() {
            switch current.type {
            case "class_declaration", "interface_declaration", "enum_declaration",
                 "record_declaration", "annotation_type_declaration":
                let name = typeName(of: current) ?? ""
                buildType(current, qualifiedName: qualifiedName.isEmpty ? name : qualifiedName + "." + name,
                          declarations: &declarations, children: &children)
            case "method_declaration", "constructor_declaration", "compact_constructor_declaration":
                if let methodScope = buildExecutable(current, owner: qualifiedName) { children.append(methodScope) }
            case "field_declaration":
                buildField(current, owner: qualifiedName, scopeEnd: scopeEnd,
                           declarations: &declarations, children: &children)
            case "ERROR":
                stack += current.namedChildren
            default:
                break
            }
        }
    }

    func buildLambda(_ node: SyntaxNode) -> JavaScopeTree.Scope {
        var declarations: [JavaScopeTree.Declaration] = []
        let scopeEnd = node.byteRange.upperBound
        if let parameters = node.child(byFieldName: "parameters") {
            if parameters.type == "formal_parameters" {
                for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                    guard let typeNode = parameter.child(byFieldName: "type"),
                          let nameNode = parameter.child(byFieldName: "name") else { continue }
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .parameter(name: nameNode.text, file: url, declarationRange: nameNode.byteRange,
                                           type: JavaTypeNodeConverter.convert(typeNode)),
                        visibleRange: nameNode.byteRange.upperBound..<scopeEnd))
                }
            } else {
                let names: [SyntaxNode]
                if parameters.type == "inferred_parameters" {
                    names = parameters.namedChildren.filter { $0.type == "identifier" }
                } else if parameters.type == "identifier" {
                    names = [parameters]
                } else {
                    names = []
                }
                let target = JavaLocalScope.expressionTarget(of: node)
                for (position, identifier) in names.enumerated() {
                    declarations.append(JavaScopeTree.Declaration(
                        symbol: .parameter(name: identifier.text, file: url, declarationRange: identifier.byteRange,
                                           type: .unresolved(simpleName: "Object", arguments: [])),
                        visibleRange: identifier.byteRange.upperBound..<scopeEnd,
                        lambdaOrigin: target.map { JavaLambdaOrigin(target: $0, parameterIndex: position) }))
                }
            }
        }
        var children: [JavaScopeTree.Scope] = []
        if let body = node.child(byFieldName: "body") {
            if body.type == "block" {
                children.append(buildBlock(body))
            } else {
                children += expressionScopes(in: body)
            }
        }
        return JavaScopeTree.Scope(kind: .lambda, range: node.byteRange, declarations: declarations, children: children)
    }
}

/// One memoized tree per parse; the URL rides along because a parse doesn't know its file.
final class JavaScopeTreeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [URL: JavaScopeTree] = [:]

    func tree(for url: URL, build: () -> JavaScopeTree) -> JavaScopeTree {
        lock.lock()
        if let existing = trees[url] { lock.unlock(); return existing }
        lock.unlock()
        let built = build()
        lock.lock()
        trees[url] = built
        lock.unlock()
        return built
    }
}
