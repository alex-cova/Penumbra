import AppKit
import Observation
import Synchronization

/// The shell's colour scheme and UI font, as one observable value.
///
/// Reading `scheme`, `fontFamily` or `fontSize` inside a SwiftUI `body` registers a dependency, so
/// every view that draws with an `IDEAppearance` token redraws when the user changes theme or
/// font; no view needs an epoch counter or an `.id` to be told. The values sit behind a lock, so
/// the reads stay legal from the few `nonisolated` places that format markdown and diagrams off the
/// main actor. Only the main actor writes (`IDEPreferences`).
///
/// AppKit views that paint their own colours do not take part in SwiftUI's tracking; they listen
/// to `IDEAppearance.didChangeNotification` through `IDEAppearanceObserver`.
final class IDEThemeStore: Observable, Sendable {
    static let shared = IDEThemeStore()

    private struct State {
        var scheme: IDEUIColorScheme = IDEUmbraUIColorScheme.shared
        var fontFamily = IDEUIFonts.defaultFamilyName
        var fontSize = IDEUIFonts.defaultFontSize
    }

    private let registrar = ObservationRegistrar()
    private let state = Mutex(State())

    var scheme: IDEUIColorScheme {
        access(keyPath: \.scheme)
        return state.withLock { $0.scheme }
    }

    var fontFamily: String {
        access(keyPath: \.fontFamily)
        return state.withLock { $0.fontFamily }
    }

    var fontSize: Double {
        access(keyPath: \.fontSize)
        return state.withLock { $0.fontSize }
    }

    /// Switches the colour scheme. Does nothing when it is already the current one.
    func setScheme(_ scheme: IDEUIColorScheme) {
        guard state.withLock({ $0.scheme != scheme }) else { return }
        withMutation(keyPath: \.scheme) {
            state.withLock { $0.scheme = scheme }
        }
        NotificationCenter.default.post(name: IDEAppearance.didChangeNotification, object: nil)
    }

    func setFontFamily(_ family: String) {
        guard state.withLock({ $0.fontFamily != family }) else { return }
        withMutation(keyPath: \.fontFamily) {
            state.withLock { $0.fontFamily = family }
        }
        NotificationCenter.default.post(name: IDEAppearance.didChangeNotification, object: nil)
    }

    func setFontSize(_ size: Double) {
        guard state.withLock({ $0.fontSize != size }) else { return }
        withMutation(keyPath: \.fontSize) {
            state.withLock { $0.fontSize = size }
        }
        NotificationCenter.default.post(name: IDEAppearance.didChangeNotification, object: nil)
    }

    private func access<Member>(keyPath: KeyPath<IDEThemeStore, Member>) {
        registrar.access(self, keyPath: keyPath)
    }

    private func withMutation<Member, Result>(
        keyPath: KeyPath<IDEThemeStore, Member>,
        _ mutation: () throws -> Result
    ) rethrows -> Result {
        try registrar.withMutation(of: self, keyPath: keyPath, mutation)
    }
}

/// Runs a closure on the main actor whenever the scheme or the UI font changes. For AppKit views
/// that colour themselves once (when they are made or shown) and so need telling; hold it as a
/// property and capture the view weakly in the closure.
@MainActor
final class IDEAppearanceObserver {
    /// Written in `init`, read in `deinit`, which run without other access.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(_ handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: IDEAppearance.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
