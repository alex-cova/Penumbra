import EditorIntelligence
import SwiftUI

/// A collapsible file header of the Problems panel: file name, directory, and problem count.
struct IDEProblemFileHeader: View {
    let file: ProblemFile
    let isCollapsed: Bool
    let directory: String
    let onToggle: () -> Void

    var body: some View {
        IDEFileGroupHeader(
            name: file.url.lastPathComponent, directory: directory,
            count: file.rows.count, noun: "problems", isCollapsed: isCollapsed
        ) { onToggle() }
    }
}
