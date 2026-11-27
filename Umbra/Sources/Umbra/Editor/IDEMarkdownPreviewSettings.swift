import AppKit
import Penumbra

/// Settings ▸ Markdown: how the Markdown preview reads. Stored as one JSON value
/// (`IDEPreferences.markdownPreview`) and handed to every preview as `MarkdownPreviewOptions`.
/// The light/dark choice is kept apart, in ``IDEMarkdownPreviewAppearance``, because the
/// preview's own sun/moon button changes it too.
struct IDEMarkdownPreviewSettings: Codable, Equatable {
    enum Typeface: String, Codable, CaseIterable, Identifiable {
        case editor, system, serif, monospaced, custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .editor: return "Editor Font"
            case .system: return "San Francisco"
            case .serif: return "New York (Serif)"
            case .monospaced: return "SF Mono"
            case .custom: return "Other…"
            }
        }
    }

    enum LineSpacing: String, Codable, CaseIterable, Identifiable {
        case compact, normal, relaxed
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum HeadingAlignment: String, Codable, CaseIterable, Identifiable {
        case leading, center
        var id: String { rawValue }
        var displayName: String { self == .leading ? "Left" : "Centered" }
    }

    enum TableDensity: String, Codable, CaseIterable, Identifiable {
        case padded, compact
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    var typeface: Typeface = .editor
    /// The family `Typeface.custom` uses.
    var customFontFamily: String = ""
    var followsEditorFontSize = true
    var fontSize = 15
    var lineSpacing: LineSpacing = .normal
    var limitsLineLength = false
    var lineLength = 80
    var headingAlignment: HeadingAlignment = .leading
    var numbersHeadings = false
    var indentsParagraphs = false
    var justifiesParagraphs = false
    var tableDensity: TableDensity = .padded
    var opensDiagramsOnClick = true
    var animatesAppearance = true
    /// Shows the preview next to the editor instead of over it, so the rendered page follows
    /// the buffer live while it stays editable.
    var sideBySide = false

    static let fontSizeRange = Int(MarkdownPreviewOptions.fontSizeRange.lowerBound)...Int(MarkdownPreviewOptions.fontSizeRange.upperBound)
    static let lineLengthRange = MarkdownPreviewOptions.lineLengthRange

    init() {}

    /// Every field is optional on decode, so settings saved by an older build keep their defaults
    /// for what they did not have.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IDEMarkdownPreviewSettings()
        typeface = (try? container.decodeIfPresent(Typeface.self, forKey: .typeface)) ?? defaults.typeface
        customFontFamily = (try? container.decodeIfPresent(String.self, forKey: .customFontFamily)) ?? defaults.customFontFamily
        followsEditorFontSize = (try? container.decodeIfPresent(Bool.self, forKey: .followsEditorFontSize)) ?? defaults.followsEditorFontSize
        fontSize = (try? container.decodeIfPresent(Int.self, forKey: .fontSize)) ?? defaults.fontSize
        lineSpacing = (try? container.decodeIfPresent(LineSpacing.self, forKey: .lineSpacing)) ?? defaults.lineSpacing
        limitsLineLength = (try? container.decodeIfPresent(Bool.self, forKey: .limitsLineLength)) ?? defaults.limitsLineLength
        lineLength = (try? container.decodeIfPresent(Int.self, forKey: .lineLength)) ?? defaults.lineLength
        headingAlignment = (try? container.decodeIfPresent(HeadingAlignment.self, forKey: .headingAlignment)) ?? defaults.headingAlignment
        numbersHeadings = (try? container.decodeIfPresent(Bool.self, forKey: .numbersHeadings)) ?? defaults.numbersHeadings
        indentsParagraphs = (try? container.decodeIfPresent(Bool.self, forKey: .indentsParagraphs)) ?? defaults.indentsParagraphs
        justifiesParagraphs = (try? container.decodeIfPresent(Bool.self, forKey: .justifiesParagraphs)) ?? defaults.justifiesParagraphs
        tableDensity = (try? container.decodeIfPresent(TableDensity.self, forKey: .tableDensity)) ?? defaults.tableDensity
        opensDiagramsOnClick = (try? container.decodeIfPresent(Bool.self, forKey: .opensDiagramsOnClick)) ?? defaults.opensDiagramsOnClick
        animatesAppearance = (try? container.decodeIfPresent(Bool.self, forKey: .animatesAppearance)) ?? defaults.animatesAppearance
        sideBySide = (try? container.decodeIfPresent(Bool.self, forKey: .sideBySide)) ?? defaults.sideBySide
    }

    /// What the preview engine takes.
    var options: MarkdownPreviewOptions {
        let face: MarkdownPreviewOptions.Typeface
        switch typeface {
        case .editor: face = .editor
        case .system: face = .system
        case .serif: face = .serif
        case .monospaced: face = .monospaced
        case .custom: face = customFontFamily.isEmpty ? .editor : .custom(customFontFamily)
        }
        return MarkdownPreviewOptions(
            typeface: face,
            fontSize: followsEditorFontSize ? nil : CGFloat(fontSize),
            lineSpacing: MarkdownPreviewOptions.LineSpacing(rawValue: lineSpacing.rawValue) ?? .normal,
            maxLineLength: limitsLineLength ? lineLength : nil,
            headingAlignment: MarkdownPreviewOptions.HeadingAlignment(rawValue: headingAlignment.rawValue) ?? .leading,
            numbersHeadings: numbersHeadings,
            indentsParagraphs: indentsParagraphs,
            justifiesParagraphs: justifiesParagraphs,
            tableDensity: MarkdownPreviewOptions.TableDensity(rawValue: tableDensity.rawValue) ?? .padded,
            opensDiagramsOnClick: opensDiagramsOnClick,
            animatesAppearance: animatesAppearance
        )
    }

    static let defaultsKey = "com.umbra.markdown.previewSettings"

    static func load(from defaults: UserDefaults) -> IDEMarkdownPreviewSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(IDEMarkdownPreviewSettings.self, from: data)
        else { return IDEMarkdownPreviewSettings() }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// The light/dark choice as a settings picker sees it: following the editor is a choice too.
enum IDEMarkdownPreviewAppearanceChoice: String, CaseIterable, Identifiable {
    case editor, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .editor: return "Match Editor Theme"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    init(_ appearance: MarkdownPreviewAppearance?) {
        switch appearance {
        case .light: self = .light
        case .dark: self = .dark
        case nil: self = .editor
        }
    }

    var appearance: MarkdownPreviewAppearance? {
        switch self {
        case .editor: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
