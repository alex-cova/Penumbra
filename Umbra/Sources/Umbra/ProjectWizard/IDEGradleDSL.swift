enum IDEGradleDSL: String, CaseIterable, Identifiable, Sendable {
    case kotlin = "Kotlin"
    case groovy = "Groovy"

    var id: Self { self }

    var scriptExtension: String {
        switch self {
        case .kotlin: "gradle.kts"
        case .groovy: "gradle"
        }
    }
}
