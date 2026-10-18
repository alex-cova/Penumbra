import Foundation

/// A group of intention actions, matching the groups under Settings › Java › Intentions.
public enum JavaIntentionCategory: String, CaseIterable, Sendable, Hashable {
    case controlFlow
    case boolean
    case declaration
    case lambda
    case comments
    case strings
    case types

    public var title: String {
        switch self {
        case .controlFlow: "Control Flow"
        case .boolean: "Boolean"
        case .declaration: "Declaration"
        case .lambda: "Lambda"
        case .comments: "Comments"
        case .strings: "Strings"
        case .types: "Types"
        }
    }
}

/// One intention action: an optional rewrite, not a problem fix. The id is stable; settings store
/// the ones the user turned off.
public struct JavaIntention: Sendable, Hashable, Identifiable {
    public let id: String
    public let category: JavaIntentionCategory
    public let title: String
    public let summary: String
    public let before: String
    public let after: String

    public var kind: String { "intention.\(id)" }

    public static let invertIf = JavaIntention(
        id: "java.intention.invertIf", category: .controlFlow, title: "Invert 'if' condition",
        summary: "Swaps the branches of an if-else and negates the condition.",
        before: "if (ready) go(); else wait();", after: "if (!ready) wait(); else go();"
    )
    public static let flipComparison = JavaIntention(
        id: "java.intention.flipComparison", category: .controlFlow, title: "Flip comparison",
        summary: "Swaps the two sides of a comparison and turns the operator around.",
        before: "a < b", after: "b > a"
    )
    public static let ifToTernary = JavaIntention(
        id: "java.intention.ifToTernary", category: .controlFlow, title: "Replace if-else with '?:'",
        summary: "An if-else that returns or assigns in both branches becomes one conditional expression.",
        before: "if (ready) return 1; else return 0;", after: "return ready ? 1 : 0;"
    )
    public static let ternaryToIf = JavaIntention(
        id: "java.intention.ternaryToIf", category: .controlFlow, title: "Replace '?:' with if-else",
        summary: "A conditional expression used as a return or an assignment becomes an if-else.",
        before: "return ready ? 1 : 0;", after: "if (ready) return 1; else return 0;"
    )
    public static let addBraces = JavaIntention(
        id: "java.intention.addBraces", category: .controlFlow, title: "Add braces",
        summary: "Puts braces around the body of an if, loop, or else.",
        before: "if (ready) go();", after: "if (ready) {\n    go();\n}"
    )
    public static let removeBraces = JavaIntention(
        id: "java.intention.removeBraces", category: .controlFlow, title: "Remove braces",
        summary: "Drops the braces around a body that holds a single statement.",
        before: "if (ready) { go(); }", after: "if (ready) go();"
    )
    public static let splitIf = JavaIntention(
        id: "java.intention.splitIf", category: .controlFlow, title: "Split into nested 'if's",
        summary: "An if whose condition is && becomes two nested ifs. An else stays put, so it is not split.",
        before: "if (a && b) go();", after: "if (a) {\n    if (b) go();\n}"
    )
    public static let mergeIf = JavaIntention(
        id: "java.intention.mergeIf", category: .controlFlow, title: "Merge nested 'if's",
        summary: "Two nested ifs with no else become one if whose condition is &&.",
        before: "if (a) { if (b) go(); }", after: "if (a && b) go();"
    )
    public static let deMorgan = JavaIntention(
        id: "java.intention.deMorgan", category: .boolean, title: "Apply De Morgan's laws",
        summary: "Pushes a negation into a conjunction or disjunction, or pulls two negations back out.",
        before: "!(a && b)", after: "!a || !b"
    )
    public static let splitDeclaration = JavaIntention(
        id: "java.intention.splitDeclaration", category: .declaration, title: "Split into declaration and assignment",
        summary: "A local with an initializer becomes a declaration followed by an assignment.",
        before: "int count = 1;", after: "int count;\ncount = 1;"
    )
    public static let joinDeclaration = JavaIntention(
        id: "java.intention.joinDeclaration", category: .declaration, title: "Join declaration and assignment",
        summary: "A declaration whose next statement assigns it becomes one declaration.",
        before: "int count;\ncount = 1;", after: "int count = 1;"
    )
    public static let expandLambda = JavaIntention(
        id: "java.intention.expandLambda", category: .lambda, title: "Expand lambda body",
        summary: "An expression lambda becomes a block. A statement stays a statement; a value is returned.",
        before: "x -> x + 1", after: "x -> { return x + 1; }"
    )
    public static let collapseLambda = JavaIntention(
        id: "java.intention.collapseLambda", category: .lambda, title: "Collapse lambda body",
        summary: "A block that only returns or runs one expression becomes an expression lambda.",
        before: "x -> { return x + 1; }", after: "x -> x + 1"
    )
    public static let lineCommentsToBlock = JavaIntention(
        id: "java.intention.lineCommentsToBlock", category: .comments, title: "Convert to block comment",
        summary: "Consecutive line comments become one block comment.",
        before: "// one\n// two", after: "/*\n * one\n * two\n */"
    )
    public static let blockCommentToLines = JavaIntention(
        id: "java.intention.blockCommentToLines", category: .comments, title: "Convert to line comments",
        summary: "A block comment of plain text becomes line comments. A doc comment stays a doc comment.",
        before: "/* one\n   two */", after: "// one\n// two"
    )
    public static let textBlock = JavaIntention(
        id: "java.intention.textBlock", category: .strings, title: "Replace with text block",
        summary: "A chain of string literals joined with + and line breaks becomes a text block.",
        before: "\"a\\n\" + \"b\\n\" + \"c\"", after: "\"\"\"\n    a\n    b\n    c\"\"\""
    )
    public static let explicitToVar = JavaIntention(
        id: "java.intention.explicitToVar", category: .types, title: "Replace explicit type with 'var'",
        summary: "A local with an initializer is declared with var. A diamond, a lambda, or an array initializer is left alone.",
        before: "String name = \"Ada\";", after: "var name = \"Ada\";"
    )
    public static let varToExplicit = JavaIntention(
        id: "java.intention.varToExplicit", category: .types, title: "Replace 'var' with explicit type",
        summary: "A var local is written with the type of its initializer, when that type can be named.",
        before: "var count = 1;", after: "int count = 1;"
    )

    public static let all: [JavaIntention] = [
        invertIf, flipComparison, ifToTernary, ternaryToIf, addBraces, removeBraces, splitIf, mergeIf,
        deMorgan, splitDeclaration, joinDeclaration, expandLambda, collapseLambda,
        lineCommentsToBlock, blockCommentToLines, textBlock, explicitToVar, varToExplicit,
    ]

    public static func named(_ id: String) -> JavaIntention? {
        all.first { $0.id == id }
    }

    public static func inCategory(_ category: JavaIntentionCategory) -> [JavaIntention] {
        all.filter { $0.category == category }
    }
}

/// Which intentions are on, and whether the editor draws the bulb and the preview.
public struct JavaIntentionOptions: Sendable, Equatable {
    public var disabledIDs: Set<String>
    public var showsBulb: Bool
    public var showsPreview: Bool

    public static let standard = JavaIntentionOptions()

    public init(disabledIDs: Set<String> = [], showsBulb: Bool = true, showsPreview: Bool = true) {
        self.disabledIDs = disabledIDs
        self.showsBulb = showsBulb
        self.showsPreview = showsPreview
    }

    public func isEnabled(_ intention: JavaIntention) -> Bool {
        !disabledIDs.contains(intention.id)
    }

    /// Missing switches mean the default, which is on. `disabledIDs` lists only the ones turned off.
    public static func restored(disabledIDs: [String]?, showsBulb: Bool?, showsPreview: Bool?) -> JavaIntentionOptions {
        JavaIntentionOptions(
            disabledIDs: Set(disabledIDs ?? []),
            showsBulb: showsBulb ?? true,
            showsPreview: showsPreview ?? true
        )
    }
}

/// Commands the chevron on an intention row sends to the host. The argument is the intention id.
public enum JavaIntentionCommand {
    public static let disable = "java.intention.disable"
    public static let configure = "java.intention.configure"
}
