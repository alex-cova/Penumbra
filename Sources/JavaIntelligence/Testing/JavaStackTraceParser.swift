import Foundation

public struct JavaStackFrame: Sendable, Hashable {
    public let className: String
    public let methodName: String
    public let fileName: String?
    /// 1-based line; `nil` for `Native Method`, `Unknown Source` or a frame without a line.
    public let line: Int?
    public let isNative: Bool

    public init(className: String, methodName: String, fileName: String?, line: Int?, isNative: Bool = false) {
        self.className = className
        self.methodName = methodName
        self.fileName = fileName
        self.line = line
        self.isNative = isNative
    }
}

public enum JavaStackTraceParser {
    /// Package prefixes that are never "project code" for a test failure.
    public static let frameworkPrefixes = [
        "java.", "javax.", "jdk.", "sun.", "com.sun.", "org.junit.", "org.opentest4j.", "org.gradle.",
        "worker.org.gradle.", "junit.framework.", "org.apache.tools.ant.", "kotlin.", "kotlinx."
    ]

    /// Every `at ...` frame in `text`, in order (also across `Caused by:` sections).
    public static func frames(in text: String) -> [JavaStackFrame] {
        var result: [JavaStackFrame] = []
        text.enumerateLines { line, _ in
            if let frame = frame(fromLine: line) { result.append(frame) }
        }
        return result
    }

    /// Parses `at pkg.Cls.method(Cls.java:42)`, tolerating a module prefix (`java.base/…`,
    /// `app//…`), `Native Method` and `Unknown Source`.
    public static func frame(fromLine line: String) -> JavaStackFrame? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("at ") else { return nil }
        text.removeFirst(3)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        var qualified = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        let location = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        if let slash = qualified.lastIndex(of: "/") {
            qualified = String(qualified[qualified.index(after: slash)...])
        }
        guard let dot = qualified.lastIndex(of: "."), dot != qualified.startIndex else { return nil }
        let className = String(qualified[..<dot])
        let methodName = String(qualified[qualified.index(after: dot)...])
        guard !className.isEmpty, !methodName.isEmpty, !className.contains(" ") else { return nil }

        var fileName: String?
        var lineNumber: Int?
        var isNative = false
        if location == "Native Method" {
            isNative = true
        } else if location != "Unknown Source" {
            if let colon = location.lastIndex(of: ":"), let n = Int(location[location.index(after: colon)...]) {
                fileName = String(location[..<colon])
                lineNumber = n
            } else if !location.isEmpty {
                fileName = location
            }
        }
        return JavaStackFrame(className: className, methodName: methodName, fileName: fileName, line: lineNumber, isNative: isNative)
    }

    /// The first frame that is neither JDK, JUnit nor Gradle code: where a failure originated in the
    /// project. `excluding` replaces ``frameworkPrefixes``.
    public static func firstProjectFrame(in frames: [JavaStackFrame], excluding: [String] = frameworkPrefixes) -> JavaStackFrame? {
        frames.first { frame in
            !frame.isNative && frame.line != nil && !excluding.contains { frame.className.hasPrefix($0) }
        }
    }

    public static func firstProjectFrame(in text: String, excluding: [String] = frameworkPrefixes) -> JavaStackFrame? {
        firstProjectFrame(in: frames(in: text), excluding: excluding)
    }
}
