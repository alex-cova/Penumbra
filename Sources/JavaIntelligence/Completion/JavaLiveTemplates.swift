import EditorIntelligence
import Foundation

/// Java live templates (`sout`, `psvm`, …). Statement templates and class-body templates are
/// separate lists. Ordinary completion offers them once a letter is typed; `Filter.templates`
/// (⌘J) offers the whole list for the caret's site.
enum JavaLiveTemplates {
    enum Site {
        case statement
        case classBody
    }

    static func items(
        site: Site, prefix: String, includeWhenPrefixEmpty: Bool, bytes: [UInt8], prefixStart: Int,
        tree: JavaSyntaxTree, factory: JavaCompletionItemFactory, source: String
    ) -> [CompletionItem] {
        guard includeWhenPrefixEmpty || !prefix.isEmpty else { return [] }
        let indentation = JavaPostfixTemplates.lineIndentation(bytes: bytes, at: prefixStart)
        let step = indentation.contains("\t") ? "\t" : "    "
        let inner = indentation + step
        let names = enclosingNames(in: tree, at: prefixStart)
        var templates: [(String, String, String)] = []
        switch site {
        case .statement:
            templates = statementTemplates(inner: inner, indentation: indentation, names: names)
        case .classBody:
            templates = classBodyTemplates(inner: inner, indentation: indentation)
        }
        return templates.map { key, description, body in
            CompletionItem(
                label: key, insertText: body, kind: .snippet, range: factory.range, source: source,
                filterText: key, detail: description, priority: JavaCompletionPriority.keyword,
                allowsAutoInsert: false
            )
        }
    }

    private static func statementTemplates(inner: String, indentation: String, names: (type: String, method: String)) -> [(String, String, String)] {
        let soutm = "System.out.println(\"\(JavaPostfixTemplates.snippetText(names.type)).\(JavaPostfixTemplates.snippetText(names.method))\");$0"
        return [
            ("sout", "System.out.println()", "System.out.println($0);"),
            ("souf", "System.out.printf()", "System.out.printf(\"${1:%s}%n\", $2);$0"),
            ("soutv", "println(\"x = \" + x)", "System.out.println(\"${1:x} = \" + ${1:x});$0"),
            ("soutm", "println(Class.method)", soutm),
            ("serr", "System.err.println()", "System.err.println($0);"),
            ("fori", "for (i = 0; i < n)", block("for (int ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++)", inner: inner, indentation: indentation)),
            ("iter", "for (element : collection)", block("for (${1:Element} ${2:element} : ${3:collection})", inner: inner, indentation: indentation)),
            ("itar", "for (i < array.length)", itar(inner: inner, indentation: indentation)),
            ("ifn", "if (expr == null)", block("if (${1:expr} == null)", inner: inner, indentation: indentation)),
            ("inn", "if (expr != null)", block("if (${1:expr} != null)", inner: inner, indentation: indentation)),
            ("thr", "throw new RuntimeException()", "throw new ${1:RuntimeException}($0);"),
            ("St", "String", "String "),
            ("todo", "// TODO", "// TODO: $0")
        ]
    }

    private static func classBodyTemplates(inner: String, indentation: String) -> [(String, String, String)] {
        [
            ("psvm", "public static void main", block("public static void main(String[] args)", inner: inner, indentation: indentation)),
            ("main", "public static void main", block("public static void main(String[] args)", inner: inner, indentation: indentation)),
            ("psf", "public static final", "public static final "),
            ("psfs", "public static final String", "public static final String "),
            ("psfi", "public static final int", "public static final int "),
            ("prsf", "private static final", "private static final "),
            ("St", "String", "String "),
            ("lazy", "lazy holder", lazy(inner: inner, indentation: indentation)),
            ("todo", "// TODO", "// TODO: $0")
        ]
    }

    private static func block(_ header: String, inner: String, indentation: String) -> String {
        "\(header) {\n\(inner)$0\n\(indentation)}"
    }

    private static func itar(inner: String, indentation: String) -> String {
        """
        for (int ${1:i} = 0; ${1:i} < ${2:array}.length; ${1:i}++) {
        \(inner)${3:Element} ${4:element} = ${2:array}[${1:i}];
        \(inner)$0
        \(indentation)}
        """
    }

    private static func lazy(inner: String, indentation: String) -> String {
        """
        private ${1:Type} ${2:name};

        \(indentation)public ${1:Type} get${3:Name}() {
        \(inner)if (${2:name} == null) {
        \(inner)\(inner)${2:name} = new ${1:Type}($0);
        \(inner)}
        \(inner)return ${2:name};
        \(indentation)}
        """
    }

    private static func enclosingNames(in tree: JavaSyntaxTree, at byteOffset: Int) -> (type: String, method: String) {
        var type = "Class"
        var method = "method"
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if node.type == "method_declaration" || node.type == "constructor_declaration",
               let name = node.child(byFieldName: "name")?.text, method == "method" {
                method = name
            }
            if ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"].contains(node.type),
               let name = node.child(byFieldName: "name")?.text {
                type = name
                break
            }
            current = node.parent
        }
        return (type, method)
    }
}
