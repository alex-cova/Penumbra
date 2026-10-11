import HexKit
import SwiftUI

/// Data inspector for the caret, or the first 8 bytes of a selection.
/// Integer and float rows write their bytes back when the field is submitted.
struct IDEHexInspectorView: View {
    @Bindable var session: IDEHexSession
    @State private var hashes: (md5: String, sha1: String, sha256: String)?
    @State private var drafts: [String: String] = [:]
    @State private var invalid: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    session.setInspectorVisible(false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                        Text("Data Inspector")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("Collapse Data Inspector")
                .accessibilityLabel("Collapse Data Inspector")
                Spacer()
                Button(session.littleEndianFirst ? "LE" : "BE") {
                    session.littleEndianFirst.toggle()
                }
                .font(.caption)
                .help("Endianness of the integer and float rows")
            }
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.inspectorFields(), id: \.name) { field in
                        row(field)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            if let length = session.selectionLengthText() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Length \(length.decimal) (\(length.hex))")
                        .font(.caption.monospaced())
                    if let hashes {
                        Text("MD5 \(hashes.md5)").font(.caption2.monospaced())
                        Text("SHA-1 \(hashes.sha1)").font(.caption2.monospaced())
                        Text("SHA-256 \(hashes.sha256)").font(.caption2.monospaced())
                    } else {
                        Button("Hash") { hash() }
                    }
                }
                .padding(8)
            }
        }
        .onChange(of: session.selection) { _, _ in resetDrafts(clearHashes: true) }
        .onChange(of: session.littleEndianFirst) { _, _ in resetDrafts(clearHashes: false) }
        .onChange(of: session.renderGeneration) { _, _ in resetDrafts(clearHashes: false) }
    }

    @ViewBuilder
    private func row(_ field: HexInspectorField) -> some View {
        HStack(spacing: 6) {
            Text(field.name)
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .onTapGesture(count: 2) { copy(field.text) }
            if let spec = field.edit, field.available {
                TextField(field.name, text: draft(for: field))
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.readOnly)
                    .onSubmit { commit(field, spec: spec) }
                    .help(session.readOnly ? "Read-only" : "Return writes these bytes")
                    .background(invalid.contains(field.name) ? IDEAppearance.ColorToken.error.opacity(0.18) : Color.clear)
            } else {
                Text(field.text)
                    .foregroundStyle(field.available ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { copy(field.text) }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func draft(for field: HexInspectorField) -> Binding<String> {
        Binding(
            get: { drafts[field.name] ?? field.text },
            set: { drafts[field.name] = $0 }
        )
    }

    private func commit(_ field: HexInspectorField, spec: HexInspectorEdit) {
        let text = drafts[field.name] ?? field.text
        if session.commitInspector(text, as: spec) {
            invalid.remove(field.name)
            drafts[field.name] = nil
        } else {
            invalid.insert(field.name)
        }
    }

    private func resetDrafts(clearHashes: Bool) {
        drafts.removeAll()
        invalid.removeAll()
        if clearHashes { hashes = nil }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func hash() {
        Task {
            hashes = await session.hashSelection()
        }
    }
}
