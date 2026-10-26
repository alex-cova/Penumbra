import HexKit
import SwiftUI

/// Find bar for a hex tab: hex (with `??`), text, or an integer, plus replace.
struct IDEHexFindBar: View {
    @Bindable var session: IDEHexSession
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $session.findMode) {
                    Text("Hex").tag(IDEHexFindMode.hex)
                    Text("Text").tag(IDEHexFindMode.text)
                    Text("Integer").tag(IDEHexFindMode.integer)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                TextField(placeholder, text: $session.findText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.updateFind() }
                modeOptions
                Button("Next") { session.findNext() }
                Button("Previous") { session.findPrevious() }
                Button("Close") { session.closeFindBar() }
            }
            HStack(spacing: 8) {
                TextField("Replace", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                Button("Replace") { session.replaceCurrent(with: replacement) }
                    .disabled(session.readOnly)
                Text(session.matchStatus)
                    .font(.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .onChange(of: session.findText) { _, _ in session.updateFind() }
        .onChange(of: session.findMode) { _, _ in session.updateFind() }
        .onChange(of: session.findCaseInsensitive) { _, _ in session.updateFind() }
        .onChange(of: session.findEncoding) { _, _ in session.updateFind() }
        .onChange(of: session.findIntegerWidth) { _, _ in session.updateFind() }
        .onChange(of: session.littleEndianFirst) { _, _ in
            if session.findMode == .integer { session.updateFind() }
        }
    }

    @ViewBuilder
    private var modeOptions: some View {
        switch session.findMode {
        case .text:
            Picker("Encoding", selection: $session.findEncoding) {
                ForEach(HexSearchTextEncoding.allCases, id: \.self) { encoding in
                    Text(encoding.displayName).tag(encoding)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Toggle("Aa", isOn: $session.findCaseInsensitive)
                .toggleStyle(.button)
                .help("ASCII case-insensitive")
        case .integer:
            Picker("Width", selection: $session.findIntegerWidth) {
                Text("8-bit").tag(1)
                Text("16-bit").tag(2)
                Text("32-bit").tag(4)
                Text("64-bit").tag(8)
            }
            .labelsHidden()
            .frame(width: 90)
            Button(session.littleEndianFirst ? "LE" : "BE") {
                session.littleEndianFirst.toggle()
            }
            .font(.caption.monospaced())
            .help("Byte order, shared with the data inspector")
        case .hex:
            EmptyView()
        }
    }

    private var placeholder: String {
        switch session.findMode {
        case .hex: return "4D 5A ??"
        case .text: return "Text"
        case .integer: return "305419896 or 0x12345678"
        }
    }
}
