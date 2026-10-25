import SwiftUI

/// Go to Offset. Accepts `0x1F40`, decimal, `+`/`-` relative to the caret, and `end`.
struct IDEHexGoToOffsetSheet: View {
    @Bindable var session: IDEHexSession
    @State private var text = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Offset")
                .font(.headline)
            TextField("0x1F40", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            if failed {
                Text("That offset is not a number, a relative jump, or end.")
                    .font(.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.showsGoToOffset = false }
                Button("Go") { go() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 320)
    }

    private func go() {
        failed = !session.goTo(text)
    }
}
