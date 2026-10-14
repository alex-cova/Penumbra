import JavaIntelligence
import SwiftUI

/// A button beside the VM options field that opens the common JVM options as checkboxes. It edits the
/// field's text and nothing else: an option the user typed by hand shows as checked, and unchecking
/// it removes only its own tokens.
struct IDEVMOptionsPicker: View {
    @Binding var text: String
    /// The Java feature release the run uses, when known; options it does not accept are disabled.
    let featureVersion: Int?

    @State private var isShowing = false

    var body: some View {
        Button("Common Options", systemImage: "slider.horizontal.3") { isShowing.toggle() }
            .help("Add common JVM options")
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                IDEVMOptionsList(text: $text, featureVersion: featureVersion)
            }
    }
}

private struct IDEVMOptionsList: View {
    @Binding var text: String
    let featureVersion: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                ForEach(JavaVMOption.Category.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                        Text(category.title)
                            .font(IDEAppearance.Typography.sectionHeader)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        ForEach(JavaVMOptions.options(in: category)) { option in
                            row(for: option)
                        }
                    }
                }
            }
            .padding(IDEAppearance.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380, height: 420)
    }

    private func row(for option: JavaVMOption) -> some View {
        let isAvailable = JavaVMOptions.isAvailable(option, featureVersion: featureVersion)
        return Toggle(isOn: binding(for: option)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(IDEAppearance.Typography.body)
                Text(option.text)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(isAvailable ? option.summary : "Needs Java \(option.minimumFeatureVersion ?? 0) or later.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        // A checked option stays clickable on an older JDK, so it can still be taken out.
        .disabled(!isAvailable && !JavaVMOptions.isEnabled(option, in: text))
    }

    private func binding(for option: JavaVMOption) -> Binding<Bool> {
        Binding(
            get: { JavaVMOptions.isEnabled(option, in: text) },
            set: { isOn in
                text = isOn ? JavaVMOptions.adding(option, to: text) : JavaVMOptions.removing(option, from: text)
            }
        )
    }
}
