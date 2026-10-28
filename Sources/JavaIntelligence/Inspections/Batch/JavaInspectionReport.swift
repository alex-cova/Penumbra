import Foundation

/// Results of an Inspect Code run, ready to write out: SARIF 2.1.0 for other tools and CI, or a
/// self-contained HTML page to read.
public struct JavaInspectionReport: Sendable {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let ruleCode: String
        public let message: String
        public let severity: JavaInspection.Severity
        /// 1-based, as SARIF and people count.
        public let line: Int
        public let column: Int

        public init(path: String, ruleCode: String, message: String, severity: JavaInspection.Severity, line: Int, column: Int) {
            self.path = path
            self.ruleCode = ruleCode
            self.message = message
            self.severity = severity
            self.line = line
            self.column = column
        }
    }

    /// What a report says about a rule: its title, what it finds and the group it belongs to.
    public struct RuleInfo: Sendable, Equatable {
        public let title: String
        public let summary: String
        public let group: String

        public init(title: String, summary: String, group: String) {
            self.title = title
            self.summary = summary
            self.group = group
        }
    }

    public let title: String
    public let entries: [Entry]
    /// The tool the SARIF names as its driver.
    public let toolName: String
    /// The rules the entries refer to, by code, when they are not Java's (a Swift run passes its own).
    /// `nil` reads every code as a Java inspection.
    private let rules: [String: RuleInfo]?

    public init(title: String, entries: [Entry], toolName: String = "Umbra Java Inspections", rules: [String: RuleInfo]? = nil) {
        self.title = title
        self.entries = entries
        self.toolName = toolName
        self.rules = rules
    }

    /// Builds entries from per-file findings; paths are made relative to `root` when inside it.
    public init(title: String, results: [URL: [JavaInspection]], root: URL?) {
        let prefix = root.map { $0.standardizedFileURL.path + "/" }
        var entries: [Entry] = []
        for (url, findings) in results {
            let path = url.standardizedFileURL.path
            let shown = prefix.flatMap { path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil } ?? path
            for finding in findings {
                entries.append(Entry(
                    path: shown, ruleCode: finding.id, message: finding.message, severity: finding.severity,
                    line: finding.range.start.line + 1, column: finding.range.start.column + 1
                ))
            }
        }
        entries.sort { ($0.path, $0.line, $0.column, $0.ruleCode) < ($1.path, $1.line, $1.column, $1.ruleCode) }
        self.title = title
        self.entries = entries
        self.toolName = "Umbra Java Inspections"
        self.rules = nil
    }

    private func ruleInfo(for code: String) -> RuleInfo? {
        if let rules { return rules[code] }
        return JavaInspectionRule(code: code).map { RuleInfo(title: $0.title, summary: $0.summary, group: $0.group.title) }
    }

    static func sarifLevel(_ severity: JavaInspection.Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .weakWarning, .info, .noHighlighting: "note"
        }
    }

    public func sarif() -> Data {
        let usedCodes = Array(Set(entries.map(\.ruleCode))).sorted()
        let rules: [[String: Any]] = usedCodes.map { code in
            let rule = ruleInfo(for: code)
            var object: [String: Any] = ["id": code]
            if let rule {
                object["name"] = rule.title
                object["shortDescription"] = ["text": rule.title]
                object["fullDescription"] = ["text": rule.summary]
                object["properties"] = ["category": rule.group]
            }
            return object
        }
        let results: [[String: Any]] = entries.map { entry in
            [
                "ruleId": entry.ruleCode,
                "level": Self.sarifLevel(entry.severity),
                "message": ["text": entry.message],
                "locations": [[
                    "physicalLocation": [
                        "artifactLocation": ["uri": entry.path],
                        "region": ["startLine": entry.line, "startColumn": entry.column],
                    ],
                ]],
            ]
        }
        let document: [String: Any] = [
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [[
                "tool": ["driver": ["name": toolName, "rules": rules]],
                "results": results,
            ]],
        ]
        return (try? JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    public func html() -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var rows = ""
        for entry in entries {
            let rule = ruleInfo(for: entry.ruleCode)?.title ?? entry.ruleCode
            rows += "<tr class=\"\(Self.sarifLevel(entry.severity))\"><td>\(escape(entry.severity.rawValue))</td>"
            rows += "<td>\(escape(rule))</td><td>\(escape(entry.message))</td>"
            rows += "<td>\(escape(entry.path)):\(entry.line):\(entry.column)</td></tr>\n"
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body{font:14px -apple-system,Helvetica,sans-serif;margin:24px;color:#222}
        table{border-collapse:collapse;width:100%}
        th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #ddd;vertical-align:top}
        tr.error td:first-child{color:#c00;font-weight:600}
        tr.warning td:first-child{color:#b36b00}
        </style></head><body>
        <h1>\(escape(title))</h1>
        <p>\(entries.count) problem\(entries.count == 1 ? "" : "s")</p>
        <table><tr><th>Severity</th><th>Inspection</th><th>Message</th><th>Location</th></tr>
        \(rows)</table></body></html>
        """
    }
}
