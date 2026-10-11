import HexKit
import Penumbra
import SwiftUI

extension IDEPreferencesDomain {
    /// Settings ▸ Hex. Stored on this Mac, outside the shared preferences snapshot.
    static let hex = IDEPreferencesDomain(
        id: "hex", title: "Hex", symbol: "number",
        searchTerms: [
            "hex", "binary", "bytes", "offset", "inspector", "overwrite", "encoding",
            "bytes per row", "group", "copy as"
        ]
    )
}

/// Chrome for a hex tab: status, toolbar, View menu, palette commands, and the Hex settings page.
struct IDEHexModule: IDELanguageModule {
    static let id = "hex"
    var id: String { Self.id }

    static let openAsHex = "hex.openAsHex"
    static let reopenAsText = "hex.reopenAsText"
    static let goToOffset = "hex.goToOffset"
    static let find = "hex.find"
    static let toggleInsert = "hex.toggleInsert"
    static let zeroSelection = "hex.zeroSelection"
    static let compareDisk = "hex.compareDisk"
    static let toggleBookmark = "hex.toggleBookmark"
    static let toggleInspector = "hex.toggleInspector"

    static let commandIDs = [
        openAsHex, reopenAsText, goToOffset, find, toggleInsert, zeroSelection,
        compareDisk, toggleBookmark, toggleInspector
    ]

    private func isHex(_ workspace: IDEWorkspace) -> Bool {
        if workspace.statusLanguage == "Hex" { return true }
        return workspace.workbench.activePane.selectedDocument?.contentKind == .binary
    }

    private func isText(_ workspace: IDEWorkspace) -> Bool {
        workspace.workbench.activePane.selectedDocument?.contentKind == .text
    }

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        var commands: [EditorCommand] = []
        if isText(workspace) {
            commands.append(EditorCommand(
                id: Self.openAsHex, title: "Open as Hex Editor", group: "Hex",
                action: { [weak workspace] in workspace?.reopenActiveDocumentAsHex() }
            ))
        }
        guard isHex(workspace) else { return commands }
        commands.append(contentsOf: [
            EditorCommand(id: Self.reopenAsText, title: "Reopen as Text", group: "Hex",
                          action: { [weak workspace] in workspace?.reopenActiveDocumentAsText() }),
            EditorCommand(id: Self.goToOffset, title: "Go to Offset…", group: "Hex", shortcutDisplay: "⌘L",
                          action: { [weak workspace] in workspace?.showGoToLine() }),
            EditorCommand(id: Self.find, title: "Find Bytes…", group: "Hex", shortcutDisplay: "⌘F",
                          action: { [weak workspace] in workspace?.showFind() }),
            EditorCommand(id: Self.toggleInsert, title: "Toggle Insert Mode", group: "Hex",
                          action: { [weak workspace] in workspace?.toggleHexInsertMode() }),
            EditorCommand(id: Self.zeroSelection, title: "Zero Selection", group: "Hex",
                          action: { [weak workspace] in workspace?.zeroHexSelection() }),
            EditorCommand(id: Self.compareDisk, title: "Compare with Disk", group: "Hex",
                          action: { [weak workspace] in workspace?.compareHexWithDisk() }),
            EditorCommand(id: Self.toggleBookmark, title: "Toggle Bookmark", group: "Hex",
                          action: { [weak workspace] in workspace?.toggleHexBookmark() }),
            EditorCommand(id: Self.toggleInspector, title: "Show Data Inspector", group: "Hex", shortcutDisplay: "⌥⌘I",
                          action: { [weak workspace] in workspace?.toggleHexInspector() }),
        ])
        return commands
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard isHex(workspace) else { return [] }
        let insert = workspace.activeHexSession()?.insertMode == true
        return [
            .button(
                id: "hex.insert", order: IDEToolbarItem.Order.preview, systemImage: insert ? "text.insert" : "pencil",
                help: insert ? "Insert mode" : "Overwrite mode", isActive: insert,
                action: { [weak workspace] in workspace?.toggleHexInsertMode() }
            ),
            .button(
                id: "hex.inspector", order: IDEToolbarItem.Order.preview + 1, systemImage: "info.circle",
                help: "Data Inspector", isActive: workspace.activeHexSession()?.inspectorVisible == true,
                action: { [weak workspace] in workspace?.toggleHexInspector() }
            ),
        ]
    }

    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem] {
        guard isHex(workspace), let session = workspace.activeHexSession() else { return [] }
        var items = [
            IDEStatusItem(id: "hex.offset", placement: .trailing, order: 10, content: AnyView(
                Text(session.offsetStatus).font(.caption.monospaced())
            )),
            IDEStatusItem(id: "hex.selection", placement: .trailing, order: 11, content: AnyView(
                Text(session.selectionStatus).font(.caption.monospaced())
            )),
            IDEStatusItem(id: "hex.mode", placement: .trailing, order: 12, content: AnyView(
                Button(session.modeStatus) { [weak workspace] in workspace?.toggleHexInsertMode() }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
            )),
            IDEStatusItem(id: "hex.encoding", placement: .trailing, order: 13, content: AnyView(
                Text(session.encodingStatus).font(.caption)
            )),
        ]
        if let progress = session.saveProgressText {
            items.append(IDEStatusItem(id: "hex.save", placement: .trailing, order: 14, content: AnyView(
                Text(progress).font(.caption.monospaced())
            )))
        }
        return items
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        var items: [IDEViewMenuContribution] = []
        if isText(workspace) {
            items.append(IDEViewMenuContribution(id: "hex.openAsHex") { ref in
                AnyView(Button("Open as Hex Editor") { ref.workspace?.reopenActiveDocumentAsHex() })
            })
        }
        guard isHex(workspace) else { return items }
        items.append(IDEViewMenuContribution(id: "hex.inspector") { ref in
            AnyView(Button("Data Inspector") { ref.workspace?.toggleHexInspector() })
        })
        items.append(IDEViewMenuContribution(id: "hex.reopenAsText") { ref in
            AnyView(Button("Reopen as Text") { ref.workspace?.reopenActiveDocumentAsText() })
        })
        return items
    }

    var preferencePanes: [IDEPreferencesPane] {
        [IDEPreferencesPane(domain: .hex) { _, _ in AnyView(IDEHexSettingsPage()) }]
    }
}

struct IDEHexSettingsPage: View {
    private var settings: IDEHexSettings { IDEHexSettings.shared }

    var body: some View {
        Form {
            Toggle("Open Binary Files in Hex Editor", isOn: binding(\.openBinaryAsHex))
            Toggle("Open Unknown Files by Content", isOn: binding(\.sniffUnknownFiles))
            TextField("Always open as text", text: extensions(\.forceTextExtensions))
            TextField("Always open as hex", text: extensions(\.forceHexExtensions))
            Picker("Bytes per Row", selection: binding(\.bytesPerRowSetting)) {
                Text("Auto").tag("auto")
                ForEach([8, 16, 24, 32, 48, 64], id: \.self) { Text("\($0)").tag(String($0)) }
            }
            Picker("Group Size", selection: binding(\.groupSize)) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Offset", selection: binding(\.offsetBase)) {
                Text("Hexadecimal").tag(HexOffsetBase.hexadecimal)
                Text("Decimal").tag(HexOffsetBase.decimal)
            }
            Toggle("Uppercase Digits", isOn: binding(\.uppercaseDigits))
            Toggle("Color Bytes by Class", isOn: binding(\.colorBytesByClass))
            Picker("Text Encoding", selection: binding(\.textEncoding)) {
                ForEach(HexPaneEncoding.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Copy As", selection: binding(\.copyStyle)) {
                ForEach(HexCopyStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Data Inspector", isOn: binding(\.inspectorVisible))
            Toggle("Little Endian First", isOn: binding(\.littleEndianFirst))
        }
        .padding()
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<IDEHexSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func extensions(_ keyPath: ReferenceWritableKeyPath<IDEHexSettings, [String]>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath].joined(separator: ", ") },
            set: { settings[keyPath: keyPath] = $0.split(separator: ",").map { String($0) } }
        )
    }
}
