import XCTest
import AppKit
@testable import Penumbra

/// Smoke coverage for the `viewDidChangeEffectiveAppearance()` overrides added to re-bake
/// `CGColor`-backed theme colors (see `DefaultThemeTests` for the color-source fix these pair
/// with). Live system-appearance changes can't be driven headlessly in a test, so this instead
/// forces each view's own `appearance` between `.aqua`/`.darkAqua` and calls the override
/// directly, asserting only that it runs to completion without crashing — a regression here would
/// most likely be a force-unwrap or an unguarded access to state that isn't set up yet (e.g. a nil
/// `lineDataSource`/`theme` before the view has been fully configured).
@MainActor
final class AppearanceChangeSmokeTests: XCTestCase {
    private func exerciseAppearanceChange(on view: NSView, _ body: () -> Void = {}) {
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        body()
    }

    func testCompatUIViewRebakesBackgroundColorWithoutCrashing() {
        let view = UIView(frame: .zero)
        view.backgroundColor = DefaultTheme().gutterBackgroundColor
        exerciseAppearanceChange(on: view)
    }

    func testCompatUIViewWithNoBackgroundColorDoesNotCrash() {
        let view = UIView(frame: .zero)
        exerciseAppearanceChange(on: view)
    }

    func testCaretViewRebakesCaretColorWithoutCrashing() {
        let caretView = CaretView(frame: .zero)
        caretView.caretColor = DefaultTheme().textColor
        exerciseAppearanceChange(on: caretView)
    }

    func testMinimapViewWithoutLineDataSourceDoesNotCrash() {
        // Exercises the guard in `applyTheme()`/the appearance-change path before a data source
        // (and therefore a theme) has been attached.
        let minimapView = MinimapView(frame: .zero)
        exerciseAppearanceChange(on: minimapView)
    }

    func testMinimapViewWithThemeRebakesViewportBorderWithoutCrashing() {
        let minimapView = MinimapView(frame: .zero)
        let textInputView = TextInputView(theme: DefaultTheme())
        minimapView.lineDataSource = textInputView
        minimapView.applyTheme()
        exerciseAppearanceChange(on: minimapView)
    }

    func testTextInputViewForcesReTypesetWithoutCrashing() {
        let textInputView = TextInputView(theme: DefaultTheme())
        exerciseAppearanceChange(on: textInputView)
    }

    func testMetalTextViewSurvivesAppearanceChange() throws {
        guard MetalContext.isAvailable,
              MetalActivation.resolved(
                property: true,
                deviceAvailable: true,
                defaults: UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
              ) else {
            throw XCTSkip("Metal is not available")
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        textView.setState(TextViewState(text: "let x = 1\nlet y = 2", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)

        textView.appearance = NSAppearance(named: .aqua)
        textView.viewDidChangeEffectiveAppearance()
        textView.layoutIfNeeded()
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.viewDidChangeEffectiveAppearance()
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.isMetalRenderingActive, "appearance change must not knock Metal offline")
        XCTAssertGreaterThanOrEqual(textView.metalFragmentCount, 1)
    }

    func testFindPanelBarViewRebakesBackgroundWithoutCrashing() {
        exerciseAppearanceChange(on: FindPanelBarView(frame: .zero))
    }

    func testWorkspaceSearchPanelViewRebakesColorsWithoutCrashing() {
        exerciseAppearanceChange(on: WorkspaceSearchPanelView(frame: .zero))
    }

    func testOutlineSidebarViewRebakesBackgroundWithoutCrashing() {
        exerciseAppearanceChange(on: OutlineSidebarView(frame: .zero))
    }

    func testCodeActionViewRebakesColorsWithoutCrashing() {
        exerciseAppearanceChange(on: CodeActionView(frame: .zero))
    }

    func testBreadcrumbBarViewRebakesBackgroundWithoutCrashing() {
        exerciseAppearanceChange(on: BreadcrumbBarView(frame: .zero))
    }

    func testCommandPaletteViewRebakesChromeWithoutCrashing() {
        let view = CommandPaletteView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        view.tabs = [.all, .files]
        view.selectedTab = .all
        exerciseAppearanceChange(on: view)
    }
}
