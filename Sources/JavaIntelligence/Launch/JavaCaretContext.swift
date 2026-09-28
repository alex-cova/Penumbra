import Foundation

/// Where the caret is in a Java file, in the terms Run in Context needs: the innermost type and,
/// when the caret is inside one, the method.
public struct JavaCaretContext: Equatable, Sendable {
    /// Simple name of the innermost type declaration around the caret.
    public let typeName: String
    /// Name of the method whose declaration contains the caret. Constructors don't count.
    public let methodName: String?
    /// 1-based line of that method's name, which is how a test method is identified in an index.
    public let methodNameLine: Int?

    public init(typeName: String, methodName: String?, methodNameLine: Int?) {
        self.typeName = typeName
        self.methodName = methodName
        self.methodNameLine = methodNameLine
    }
}

extension JavaStructureProvider {
    /// The type and method around `caretUTF16Offset`, or `nil` when the file has no type.
    public func caretContext(in text: String, atUTF16Offset caretUTF16Offset: Int) -> JavaCaretContext? {
        guard let root = structure(for: text, atUTF16Offset: caretUTF16Offset) else { return nil }
        let selected = selectedNode(in: root, text: text, atUTF16Offset: caretUTF16Offset)
        guard let selected, selected.kind == .method else {
            return JavaCaretContext(typeName: root.title, methodName: nil, methodNameLine: nil)
        }
        let bytes = Array(text.utf8)
        let range = selected.nameByteRange
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            return JavaCaretContext(typeName: root.title, methodName: nil, methodNameLine: nil)
        }
        let name = String(decoding: bytes[range], as: UTF8.self)
        let line = bytes[..<range.lowerBound].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        return JavaCaretContext(typeName: root.title, methodName: name, methodNameLine: line)
    }
}
