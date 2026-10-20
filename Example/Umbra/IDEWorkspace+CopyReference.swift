import AppKit
import Penumbra

/// Copy Path/Reference: the Explorer's popup, and the editor's Copy Reference items. What each
/// row says is decided by `IDECopyReference`; this file gathers the roots and shows the menu.
extension IDEWorkspace {
    var copyReferenceRoots: IDECopyReferenceRoots {
        IDECopyReferenceRoots(
            projectRoot: project.rootURL?.standardizedFileURL.path,
            repositoryRoot: gitStatus.repositoryRootPath,
            contentRoots: javaSupport.projectModel?.subprojects.map { $0.directory.standardizedFileURL.path } ?? [],
            sourceRoots: javaSupport.buildSystem?.sourceRootPaths ?? []
        )
    }

    // MARK: - Explorer

    /// The Explorer's "Copy Path/Reference…": the popup at the pointer, with the class name for a
    /// Java file.
    func showCopyReferencePopup(for url: URL) {
        var reference: [IDECopyReference.Row] = []
        if let name = IDECopyReference.javaQualifiedName(for: url, roots: copyReferenceRoots) {
            reference.append(IDECopyReference.Row(label: "Reference", value: name))
        }
        presentCopyMenu(for: url, reference: reference, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Editor

    /// Edit ▸ Copy Path/Reference… (and the editor menu's item): the popup at the caret, with the
    /// symbol under it and the selected lines.
    func showCopyPathReferenceForActiveEditor() {
        let paneID = workbench.activePaneID
        guard let url = workbench.activePane.selectedDocument?.url else { return }
        showEditorCopyPopup(paneID: paneID, url: url)
    }

    func copyReferenceContextMenuItems(context: EditorContextMenuContext, paneID: UUID, url: URL?) -> [NSMenuItem] {
        guard let url else { return [] }
        let host = host(for: paneID)
        let selection = context.selectedRange ?? host.textView.selectedRange
        var items: [NSMenuItem] = [.separator()]
        if url.pathExtension.lowercased() == "java" {
            items.append(IDEClosureMenuItem(title: "Copy Reference") { [weak host] in
                _ = host?.intelligenceController?.copyReference()
            })
        }
        items.append(IDEClosureMenuItem(title: "Copy Reference with Line Numbers") { [weak self, weak host] in
            guard let self, let textView = host?.textView else { return }
            self.copyToPasteboard(self.lineReference(in: textView, url: url, selection: selection))
        })
        items.append(IDEClosureMenuItem(title: "Copy Path/Reference…") { [weak self] in
            // The context menu is still closing; open the next one after it has.
            DispatchQueue.main.async { self?.showEditorCopyPopup(paneID: paneID, url: url) }
        })
        return items
    }

    /// `src/main/java/…/Foo.java:18-57` for the selection (the caret's line when it is empty).
    private func lineReference(in textView: TextView, url: URL, selection: NSRange) -> String {
        let start = textView.textLocation(at: selection.location)
        let end = textView.textLocation(at: selection.location + selection.length)
        let lines = IDECopyReference.lineRange(
            startLine: start?.lineNumber ?? 0,
            endLine: end?.lineNumber ?? start?.lineNumber ?? 0,
            endColumn: end?.column ?? 0,
            isEmpty: selection.length == 0
        )
        return IDECopyReference.lineReference(
            path: IDECopyReference.referencePath(for: url, roots: copyReferenceRoots), lines: lines
        )
    }

    private func showEditorCopyPopup(paneID: UUID, url: URL) {
        let host = host(for: paneID)
        let textView = host.textView
        let selection = textView.selectedRange
        let controller = url.pathExtension.lowercased() == "java" ? host.intelligenceController : nil
        Task { [weak self, weak textView] in
            let symbol = await controller?.symbolReferenceAtCaret()
            guard let self, let textView else { return }
            var rows: [IDECopyReference.Row] = []
            if let symbol {
                rows.append(IDECopyReference.Row(label: "Reference", value: symbol))
            }
            rows.append(IDECopyReference.Row(
                label: "Reference with Line Numbers",
                value: self.lineReference(in: textView, url: url, selection: selection)
            ))
            let caret = textView.caretRectInViewport(at: selection.location)
            self.presentCopyMenu(
                for: url, reference: rows, at: NSPoint(x: caret.minX, y: caret.maxY + 2), in: textView
            )
        }
    }

    // MARK: - Menu

    private func presentCopyMenu(for url: URL, reference: [IDECopyReference.Row], at point: NSPoint, in view: NSView?) {
        var sections = IDECopyReference.sections(for: url, roots: copyReferenceRoots)
        if !reference.isEmpty { sections.append(reference) }

        let menu = NSMenu(title: "Copy")
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: "Copy"))

        let font = NSFont.menuFont(ofSize: 0)
        let labelWidth = sections.joined()
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: ceil(labelWidth) + 28)]
        paragraph.lineBreakMode = .byClipping

        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for row in section {
                let item = IDEClosureMenuItem(title: row.label) { [weak self] in
                    self?.copyToPasteboard(row.value)
                }
                let title = NSMutableAttributedString(
                    string: row.label + "\t",
                    attributes: [.font: font, .paragraphStyle: paragraph]
                )
                title.append(NSAttributedString(
                    string: Self.truncatedMiddle(row.value, limit: 60),
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
                ))
                item.attributedTitle = title
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private static func truncatedMiddle(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let keep = limit - 1
        let head = keep / 2
        return String(value.prefix(keep - head)) + "…" + String(value.suffix(head))
    }
}
