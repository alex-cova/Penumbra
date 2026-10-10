import EditorIntelligence
import Foundation

enum TypeScriptLocations {
    static func make(
        bytes: Range<Int>,
        text: TypeScriptText,
        document: Document,
        file: URL?,
        name: String,
        kind: String
    ) -> Location {
        let range = text.range(bytes: bytes)
        let line = text.lineContents(containingUTF16: range.start.utf16Offset)
        let target = file?.standardizedFileURL
        let current = document.url?.standardizedFileURL
        let sameFile = target == nil || target == current
        let length = max(0, range.end.utf16Offset - range.start.utf16Offset)
        return Location(
            documentID: sameFile ? document.id : DocumentID(),
            url: target ?? current,
            range: range,
            displayName: name,
            usage: Location.UsageInfo(
                kindLabel: kind,
                isAmbiguous: false,
                lineText: line.text,
                matchRange: NSRange(location: max(0, line.column), length: length),
                line: line.line
            )
        )
    }

    static func edit(bytes: Range<Int>, text: TypeScriptText, url: URL, oldName: String, newName: String) -> WorkspaceEditPlanEntry {
        let range = text.range(bytes: bytes)
        let line = text.lineContents(containingUTF16: range.start.utf16Offset)
        return WorkspaceEditPlanEntry(
            url: url.standardizedFileURL,
            range: range,
            oldText: oldName,
            newText: newName,
            lineText: line.text
        )
    }
}
