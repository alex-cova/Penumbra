import HexKit
import SwiftUI

/// Find bar for a hex tab: hex (with `??`) or text, next and previous, and replace.
struct IDEHexFindBar: View {
    @Bindable var session: IDEHexSession
    @State private var replacement = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $session.findMode) {
                Text("Hex").tag(IDEHexFindMode.hex)
                Text("Text").tag(IDEHexFindMode.text)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            TextField(session.findMode == .hex ? "4D 5A ??" : "Text", text: $session.findText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.updateFind() }
            if session.findMode == .text {
                Toggle("Aa", isOn: $session.findCaseInsensitive)
                    .toggleStyle(.button)
                    .help("ASCII case-insensitive")
            }
            Text(session.matchStatus)
                .font(.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("Replace", text: $replacement)
                .textFieldStyle(.roundedBorder)
            Button("Next") { session.findNext() }
            Button("Previous") { session.findPrevious() }
            Button("Replace") { session.replaceCurrent(with: replacement) }
                .disabled(session.readOnly)
            Button("Close") { session.closeFindBar() }
        }
        .padding(6)
        .onChange(of: session.findText) { _, _ in session.updateFind() }
        .onChange(of: session.findMode) { _, _ in session.updateFind() }
        .onChange(of: session.findCaseInsensitive) { _, _ in session.updateFind() }
    }
}
