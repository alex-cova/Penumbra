import HexKit
import SwiftUI

/// Data inspector for the caret, or the first 8 bytes of a selection.
struct IDEHexInspectorView: View {
    @Bindable var session: IDEHexSession
    @State private var hashes: (md5: String, sha1: String, sha256: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Data Inspector")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(session.littleEndianFirst ? "LE" : "BE") {
                    session.littleEndianFirst.toggle()
                }
                .font(.caption)
                .help("Endianness of the integer and float rows")
            }
            .padding(8)
            List(session.inspectorFields(), id: \.name) { field in
                HStack {
                    Text(field.name).frame(width: 110, alignment: .leading)
                    Text(field.text)
                        .foregroundStyle(field.available ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                        .textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
                .onTapGesture(count: 2) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(field.text, forType: .string)
                }
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
        .onChange(of: session.selection) { _, _ in hashes = nil }
    }

    private func hash() {
        Task {
            hashes = await session.hashSelection()
        }
    }
}
