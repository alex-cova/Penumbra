import Foundation

/// Deterministic mutations of the parity corpus's valid sources, each aimed at `javac` keys.
///
/// A mutation is one exact-substring replacement anchored in a valid fixture. Anchors keep the
/// mutations readable and stable: when a fixture drifts, the anchor misses and the corpus fails
/// loudly instead of silently mutating the wrong line. The oracle (`JavaAnalysisServer.check`)
/// labels every mutation — a mis-remembered `expectedKeys` entry corrects itself on the first
/// run, because the test prints the oracle's actual keys.
///
/// The six mutator kinds below are the plan's first six (§0.3); later phases extend the table
/// with the remaining keys (exceptions, definite assignment, finals, static context, overrides,
/// duplicates, effectively-final captures, exhaustiveness).
enum JavaParityMutator {
    /// The plan's mutation families.
    enum Kind: String {
        /// Typo in a member, type or name (`cant.resolve*`).
        case typo
        /// A dropped import (`cant.resolve`).
        case dropImport
        /// Added, dropped or swapped call arguments (`cant.apply.symbol(s)`).
        case arguments
        /// A changed declared type (`prob.found.req`).
        case declaredType
        /// A dropped `return` (`missing.ret.stmt`).
        case dropReturn
        /// A dropped `throws` (`unreported.exception.need.to.catch.or.throw`).
        case dropThrows
    }

    struct Mutation {
        /// Stable id (`typo-member`, `drop-import`, …), used by `JAVA_PARITY_CASE` filtering.
        let id: String
        let kind: Kind
        /// Fixture file under `Fixtures/JavaParityCorpus/valid/`.
        let fixture: String
        /// Exact anchor replaced once; the mutation is void when it is absent.
        let find: String
        let replace: String
        /// Expected oracle key prefixes, one per oracle error, in line order.
        let expectedKeys: [String]
    }

    /// Replaces the first exact occurrence of `find` with `replace`; `nil` when absent.
    static func apply(_ mutation: Mutation, to text: String) -> String? {
        guard let range = text.range(of: mutation.find) else { return nil }
        var result = text
        result.replaceSubrange(range, with: mutation.replace)
        return result
    }

    static func all() -> [Mutation] {
        [
            Mutation(
                id: "typo-member", kind: .typo, fixture: "Basics.java",
                find: "return items.size();", replace: "return items.siz();",
                expectedKeys: ["compiler.err.cant.resolve.location.args"]
            ),
            Mutation(
                id: "typo-type", kind: .typo, fixture: "Basics.java",
                find: "public String join(String separator)", replace: "public Strin join(String separator)",
                expectedKeys: ["compiler.err.cant.resolve.location"]
            ),
            Mutation(
                id: "typo-name", kind: .typo, fixture: "Basics.java",
                find: "return fallback;", replace: "return fallbak;",
                expectedKeys: ["compiler.err.cant.resolve.location"]
            ),
            Mutation(
                id: "drop-import", kind: .dropImport, fixture: "Basics.java",
                find: "import java.util.List;\n", replace: "",
                expectedKeys: ["compiler.err.cant.resolve.location", "compiler.err.cant.resolve.location"]
            ),
            Mutation(
                id: "swap-args", kind: .arguments, fixture: "Basics.java",
                find: "return repeat(text, 2);", replace: "return repeat(2, text);",
                expectedKeys: ["compiler.err.prob.found.req"]
            ),
            Mutation(
                id: "drop-arg", kind: .arguments, fixture: "Basics.java",
                find: "return repeat(text, 2);", replace: "return repeat(text);",
                expectedKeys: ["compiler.err.cant.apply.symbol"]
            ),
            Mutation(
                id: "change-declared-type", kind: .declaredType, fixture: "Basics.java",
                find: "public int count()", replace: "public String count()",
                expectedKeys: ["compiler.err.prob.found.req"]
            ),
            Mutation(
                id: "drop-return", kind: .dropReturn, fixture: "Basics.java",
                find: "            result = result + separator + item;\n        }\n        return result;",
                replace: "            result = result + separator + item;\n        }",
                expectedKeys: ["compiler.err.missing.ret.stmt"]
            ),
            Mutation(
                id: "drop-throws", kind: .dropThrows, fixture: "Basics.java",
                find: ") throws java.io.IOException {", replace: ") {",
                expectedKeys: ["compiler.err.unreported.exception.need.to.catch.or.throw"]
            ),
            Mutation(
                id: "static-typo", kind: .typo, fixture: "Shapes.java",
                find: "Math.PI * radius", replace: "Math.P * radius",
                expectedKeys: ["compiler.err.cant.resolve.location"]
            ),
            Mutation(
                id: "enum-case", kind: .typo, fixture: "Shapes.java",
                find: "case RED:", replace: "case RE:",
                expectedKeys: ["compiler.err.cant.resolve.location"]
            ),
        ]
    }
}
