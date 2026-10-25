import Penumbra
import SwiftUI

struct IDEPreferencesTypePreview: View {
    let themeID: String
    let fontName: String
    let fontSize: Double
    let tabWidth: Int
    let useSpacesForTab: Bool

    private var palette: ThemePalette {
        ThemeCatalog.palette(id: themeID, fallbackDark: true)
    }

    @AppStorage("preferencesTypePreviewCollapsed") private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Label {
                        Text("Preview")
                            .font(IDEAppearance.Typography.sectionHeader)
                            .textCase(.uppercase)
                    } icon: {
                        IDEDisclosureChevron(isExpanded: !isCollapsed, size: 12)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint("Shows or hides the code preview")

            if !isCollapsed {
                previewSourceView
                    .font(Font(IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(IDEAppearance.Spacing.md)
                    .background(Color(hex: palette.background))
                    .clipShape(.rect(cornerRadius: IDEAppearance.Radius.control))
                    .accessibilityLabel(accessibilityPreview)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.lg)
        .padding(.vertical, IDEAppearance.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private var previewSourceView: Text {
        let indent = useSpacesForTab
            ? String(repeating: " ", count: tabWidth)
            : "\t"
        func token(_ string: String, _ hex: UInt32) -> Text {
            Text(string).foregroundStyle(Color(hex: hex))
        }
        let signature = Text("\(token("func ", palette.keyword))\(token("greet", palette.function))\(token("(name: ", palette.text))\(token("String", palette.type))\(token(") {\n", palette.text))")
        let body = Text("\(token("\(indent)print", palette.function))\(token("(name)\n}", palette.text))")
        return Text("\(signature)\(body)")
    }

    private var accessibilityPreview: String {
        let indent = useSpacesForTab ? "spaces" : "tabs"
        let size = fontSize.formatted(.number.precision(.fractionLength(0)))
        let themeName = palette.name
        return "Preview using \(themeName) in \(fontName) at \(size) points, indenting with \(indent), tab width \(tabWidth)"
    }
}
