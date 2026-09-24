import EditorIntelligence
import Foundation

/// Decides whether completing a class name needs an `import`, and builds the edit that adds it in
/// sorted position -- or tells the caller to insert the qualified name instead when the simple
/// name is already taken by another import or a type declared in this file.
struct JavaImportInserter {
    enum Decision: Equatable {
        /// Already visible by its simple name (same package, `java.lang`, imported, or declared here).
        case none
        /// Add this import edit alongside the insertion.
        case addImport(TextEdit)
        /// The simple name would be ambiguous: insert the qualified name.
        case useQualifiedName
    }

    private let bytes: [UInt8]
    private let text: String
    private let packageName: String
    private let imports: [(qualifiedName: String, isStatic: Bool, isOnDemand: Bool, range: Range<Int>)]
    private let packageDeclarationEnd: Int?
    private let declaredSimpleNames: Set<String>

    init(text: String, bytes: [UInt8], tree: JavaSyntaxTree, fileStubs: JavaSourceFileStubs) {
        self.text = text
        self.bytes = bytes
        self.packageName = fileStubs.packageName
        let list = JavaImportList(tree: tree)
        self.imports = list.entries.map {
            (qualifiedName: $0.qualifiedName, isStatic: $0.isStatic, isOnDemand: $0.isOnDemand, range: $0.range)
        }
        self.packageDeclarationEnd = list.packageDeclarationEnd
        self.declaredSimpleNames = Set(fileStubs.classes.map(\.simpleName))
    }

    func decision(for stub: JavaClassStub) -> Decision {
        let importName = stub.qualifiedName
        let ownerPackage = stub.packageName
        // Nested types are visible when their top-level class is; keep it simple and import the
        // nested type itself (what IntelliJ does by default).
        if stub.outerQualifiedName == nil, ownerPackage == packageName || ownerPackage == "java.lang" {
            return declaredSimpleNames.contains(stub.simpleName) && ownerPackage != packageName ? .useQualifiedName : .none
        }
        if declaredSimpleNames.contains(stub.simpleName) {
            return fileDeclares(stub) ? .none : .useQualifiedName
        }
        for existing in imports where !existing.isStatic {
            if existing.isOnDemand {
                if existing.qualifiedName == (stub.outerQualifiedName ?? ownerPackage) { return .none }
            } else if existing.qualifiedName == importName {
                return .none
            } else if existing.qualifiedName.split(separator: ".").last.map(String.init) == stub.simpleName {
                return .useQualifiedName
            }
        }
        return .addImport(importEdit(for: importName))
    }

    private func fileDeclares(_ stub: JavaClassStub) -> Bool {
        stub.packageName == packageName && declaredSimpleNames.contains(stub.simpleName)
    }

    /// `import name;` placed among the regular imports in lexicographic order, after the package
    /// declaration when there are none, or at the top of the file.
    private func importEdit(for name: String) -> TextEdit {
        let line = "import \(name);"
        let regular = imports.filter { !$0.isStatic }
        if let next = regular.first(where: { $0.qualifiedName > name }) {
            return insertion("\(line)\n", atByte: next.range.lowerBound)
        }
        if let last = regular.last ?? imports.last {
            return insertion("\n\(line)", atByte: last.range.upperBound)
        }
        if let packageDeclarationEnd {
            return insertion("\n\n\(line)", atByte: packageDeclarationEnd)
        }
        return insertion("\(line)\n\n", atByte: 0)
    }

    private func insertion(_ replacement: String, atByte byteOffset: Int) -> TextEdit {
        let position = Self.textPosition(forByteOffset: byteOffset, in: bytes)
        return TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: replacement)
    }

    /// Line, UTF-16 column and UTF-16 offset for a UTF-8 byte offset.
    static func textPosition(forByteOffset byteOffset: Int, in bytes: [UInt8]) -> TextPosition {
        let clamped = min(max(0, byteOffset), bytes.count)
        var line = 0
        var lineStart = 0
        for index in 0..<clamped where bytes[index] == 10 {
            line += 1
            lineStart = index + 1
        }
        let lineText = String(decoding: bytes[lineStart..<clamped], as: UTF8.self)
        let beforeText = String(decoding: bytes[0..<clamped], as: UTF8.self)
        return TextPosition(line: line, column: lineText.utf16.count, utf16Offset: beforeText.utf16.count)
    }
}
