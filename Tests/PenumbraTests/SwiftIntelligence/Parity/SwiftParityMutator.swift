import Foundation

/// Deterministic mutations of the Swift parity corpus's valid sources, each aimed at a `swiftc`
/// diagnostic key.
///
/// A mutation is one exact-substring replacement anchored in a valid fixture. Anchors keep the
/// mutations readable and stable: when a fixture drifts, the anchor misses and the corpus fails
/// loudly instead of silently mutating the wrong line. The oracle labels every mutation, and a
/// mis-remembered `expectedKeys` entry corrects itself on the first run, because the test prints
/// the oracle's actual keys.
enum SwiftParityMutator {
    struct Mutation {
        /// Stable id (`typo-member`, `drop-import`, …), used by `SWIFT_PARITY_CASE` filtering.
        let id: String
        /// Fixture file under `Fixtures/SwiftParityCorpus/valid/`.
        let fixture: String
        /// Exact anchor replaced once; the mutation is void when it is absent.
        let find: String
        let replace: String
        /// The oracle's diagnostic names (`-debug-diagnostic-names`), one per error.
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
                id: "typo-member", fixture: "Basics.swift",
                find: "return items.count\n", replace: "return items.cout\n",
                expectedKeys: ["could_not_find_value_member"]
            ),
            Mutation(
                id: "typo-type", fixture: "Basics.swift",
                find: "func joined(separator: String) -> String {", replace: "func joined(separator: String) -> Strin {",
                expectedKeys: ["cannot_find_type_in_scope"]
            ),
            Mutation(
                id: "typo-name", fixture: "Basics.swift",
                find: "return fallback\n", replace: "return fallbak\n",
                expectedKeys: ["cannot_find_in_scope"]
            ),
            Mutation(
                id: "drop-import", fixture: "Clock.swift",
                find: "import Foundation\n", replace: "",
                expectedKeys: ["cannot_find_in_scope", "cannot_find_in_scope"]
            ),
            Mutation(
                id: "swap-labels", fixture: "Basics.swift",
                find: "return repeated(text, times: 2)", replace: "return repeated(times: 2, text)",
                expectedKeys: ["argument_out_of_order_unnamed_named"]
            ),
            Mutation(
                id: "wrong-argument-type", fixture: "Basics.swift",
                find: "return repeated(text, times: 2)", replace: "return repeated(text, times: \"2\")",
                expectedKeys: ["cannot_convert_argument_value"]
            ),
            Mutation(
                id: "drop-arg", fixture: "Basics.swift",
                find: "return repeated(text, times: 2)", replace: "return repeated(text)",
                expectedKeys: ["missing_argument_named"]
            ),
            Mutation(
                id: "change-declared-type", fixture: "Basics.swift",
                find: "var count: Int {", replace: "var count: String {",
                expectedKeys: ["cannot_convert_to_return_type"]
            ),
            Mutation(
                id: "wrong-optional", fixture: "Basics.swift",
                find: "        if let value = Int(text) {\n            return value\n        }\n        return fallback\n",
                replace: "        return Int(text)\n",
                expectedKeys: ["optional_not_unwrapped"]
            ),
            // `missing_return_decl` is a SIL diagnostic: `-typecheck` never reaches it, which is why the
            // oracle emits SIL.
            Mutation(
                id: "drop-return", fixture: "Basics.swift",
                find: "            result = result + separator + item\n        }\n        return result\n",
                replace: "            result = result + separator + item\n        }\n",
                expectedKeys: ["missing_return_decl"]
            ),
            Mutation(
                id: "drop-try", fixture: "Basics.swift",
                find: "try joined(separator", replace: "joined(separator",
                expectedKeys: ["throwing_call_without_try"]
            ),
            Mutation(
                id: "drop-await", fixture: "Basics.swift",
                find: "return await load()", replace: "return load()",
                expectedKeys: ["async_expr_without_await"]
            ),
            Mutation(
                id: "static-typo", fixture: "Shapes.swift",
                find: "Double.pi * radius", replace: "Double.p * radius",
                expectedKeys: ["could_not_find_type_member"]
            ),
            Mutation(
                id: "enum-case", fixture: "Shapes.swift",
                find: "case .red: return", replace: "case .re: return",
                expectedKeys: ["could_not_find_type_member"]
            ),
            Mutation(
                id: "missing-witness", fixture: "Shapes.swift",
                find: "    var area: Double {\n        return side * side\n    }\n", replace: "",
                expectedKeys: ["type_does_not_conform"]
            ),
        ]
    }
}
