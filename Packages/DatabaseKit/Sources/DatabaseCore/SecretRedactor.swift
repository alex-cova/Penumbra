import Foundation

/// One place that removes secrets from text before it reaches a log, the query history, a
/// diagnostic, an exported file or an AI request. Pattern-based, so it is a safety net: the
/// primary rule is that secrets are never put into such text in the first place.
public enum SecretRedactor {
    public static let placeholder = "***"

    /// Replaces passwords and tokens in `text`:
    /// - the password of a URL (`scheme://user:secret@host` → `scheme://user:***@host`),
    /// - `password=…`, `pwd=…`, `PGPASSWORD=…`, `passwd: …`, `--password=…` and `-p<secret>` forms,
    /// - `Authorization: Bearer …` and common API-key shapes (`sk-…`, `ghp_…`, `AKIA…`),
    /// - PEM private-key blocks.
    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            // A pattern that fails to compile is a programming error caught by the first test run.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        // scheme://user:password@host
        Rule(#"([a-z][a-z0-9+.\-]*://[^\s:/@]*):([^\s@/]+)@"#, "$1:***@"),
        // key=value and key: value, where the key names a secret
        Rule(
            #"(\b(?:password|passwd|pwd|pgpassword|secret|token|api[_-]?key|access[_-]?key)\b["']?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;&"']+)"#,
            "$1***"
        ),
        Rule(#"(--password=)\S+"#, "$1***"),
        Rule(#"(Authorization:\s*(?:Bearer|Basic)\s+)\S+"#, "$1***"),
        Rule(#"\b(sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b"#, "***", options: []),
        Rule(
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            "***", options: []
        ),
    ]
}
