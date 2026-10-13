/// The source of the preview host for the iOS Simulator: `UmbraPreviewHost.app`'s executable.
///
/// It speaks the protocol of ``SwiftPreviewHostSource`` (JSON lines on a Unix socket it binds,
/// `--socket <path>` as an argument, `load`, `render`, `quit`, a `ready` event first), so the
/// session's connection and queue are the macOS host's. What differs is the process around it:
///
/// - It is an app, started with `simctl launch` and installed with `simctl install`, so it needs a
///   bundle (``infoPlist(bundleIdentifier:minimumOSVersion:)``) and an ad-hoc signature.
/// - It must adopt the scene lifecycle: an app built with the iOS 27 SDK that does not traps at
///   launch (`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, measured in
///   `Tools/PreviewSpike/ios-simulator`). `UIApplicationSceneManifest` names `UmbraSceneDelegate`.
/// - The window is a real scene window of the device's size, so `render` ignores the requested
///   `width` and `height` and reports the size it drew (`pointWidth`, `pointHeight`), as the
///   macOS host does for `fit`. Safe areas, the navigation bar's large title and the keyboard
///   guide are the system's, so `safeTop` and `safeBottom` are not used.
/// - A frame is `UIWindow.drawHierarchy` at the screen's scale (or the requested one, if finer):
///   presented sheets are part of the window's hierarchy and are in it. The status bar is not.
/// - Input is public API only, from inside the app (the routes and what each cannot do are measured
///   in `Tools/PreviewSpike/ios-simulator/input-host.swift` and tabulated in
///   `docs/SWIFTUI_PREVIEW_IOS_PLAN.md` §3). A tap (`mouse` down and up without travel) goes, in
///   order, to: the item of an open menu (`UIAction.performWithSender`), a text field's
///   `becomeFirstResponder`, a `UISlider` (its value from the point) or `UIStepper` (a step by the
///   half), `accessibilityActivate()` of the smallest accessibility element under the point, and
///   `sendActions(.touchUpInside)` of the `UIControl` under it (tab bar, back button), and last the
///   view controllers' own public API for those two (`UITabBarController.selectedIndex`,
///   `UINavigationController.popViewController`), so they still work if UIKit changes the controls
///   under its bars. SwiftUI vends
///   its accessibility tree only when the device's `ApplicationAccessibilityEnabled` preference was
///   on when the app launched (`IDESimulatorService.boot` sets it), so without it only `UIControl`s
///   and text fields respond. A press that travels is a drag: it moves a slider, or becomes scroll
///   deltas for the innermost `UIScrollView` that can move that way, or, pulled down past the top of
///   a list with a refresh control, runs the refresh; a mostly horizontal drag that starts on an
///   element with accessibility custom actions (swipe actions) is answered with the action names
///   (`route` `actions`) and the panel's choice comes back as `customAction`. `key` goes to the first
///   responder through `UIKeyInput` and `UITextInput`. Every `ack` carries a `route` (`text`,
///   `accessibility`, `control`, `slider`, `stepper`, `menu`, `scroll`, `refresh`, `actions`,
///   `customAction`, `tab`, `back`, `action`, `drag` or `none`). `elements` answers with the labelled
///   accessibility elements and their frames in window points, so a test (or a future inspector) can
///   find what is on screen, an open menu's items included. Not reachable: drag and long-press gestures,
///   `onTapGesture` (also with the button trait), the buttons of an alert, context menus, pinch, and
///   the software keyboard (it is another window, not in the frame).
///
/// The simulator process is a Mac process: it binds the socket, loads the thunk by its absolute
/// path and writes the PNG anywhere the Mac user can write.
public enum SwiftPreviewIOSHostSource {
    public static let fileName = "main.swift"

    /// The bundle's `Info.plist`: a scene manifest naming the host's scene delegate and nothing else.
    public static func infoPlist(bundleIdentifier: String, minimumOSVersion: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>
            <key>CFBundleExecutable</key><string>UmbraPreviewHost</string>
            <key>CFBundleName</key><string>UmbraPreviewHost</string>
            <key>CFBundleDisplayName</key><string>Umbra Preview</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>CFBundleShortVersionString</key><string>1</string>
            <key>MinimumOSVersion</key><string>\(minimumOSVersion)</string>
            <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
            <key>UILaunchScreen</key><dict/>
            <key>UIApplicationSceneManifest</key>
            <dict>
                <key>UIApplicationSupportsMultipleScenes</key><false/>
                <key>UISceneConfigurations</key>
                <dict>
                    <key>UIWindowSceneSessionRoleApplication</key>
                    <array>
                        <dict>
                            <key>UISceneConfigurationName</key><string>Default</string>
                            <key>UISceneDelegateClassName</key><string>UmbraSceneDelegate</string>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
        </plist>
        """
    }

    public static let text = #"""
    import Darwin
    import Foundation
    import SwiftUI
    import UIKit
    import UmbraPreviewSupport

    extension UIResponder {
        private static weak var capturedFirstResponder: UIResponder?
        @objc func umbraCaptureFirstResponder() { UIResponder.capturedFirstResponder = self }
        /// The public way to find the first responder: send an action to nobody and see who answers.
        static func currentFirstResponder() -> UIResponder? {
            capturedFirstResponder = nil
            UIApplication.shared.sendAction(#selector(umbraCaptureFirstResponder), to: nil, from: nil, for: nil)
            return capturedFirstResponder
        }
    }

    @MainActor
    final class PreviewHost {
        static let shared = PreviewHost()

        var window: UIWindow?
        var client: Int32 = -1
        var hasPreviewView = false
        /// `ready` is sent once the socket has a client and the scene has a window, in either order.
        var announced = false

        /// `DynamicTypeSize`'s case names, as `UIContentSizeCategory`.
        static func category(forDynamicType name: String) -> UIContentSizeCategory {
            switch name {
            case "xSmall": return .extraSmall
            case "small": return .small
            case "medium": return .medium
            case "xLarge": return .extraLarge
            case "xxLarge": return .extraExtraLarge
            case "xxxLarge": return .extraExtraExtraLarge
            case "accessibility1": return .accessibilityMedium
            case "accessibility2": return .accessibilityLarge
            case "accessibility3": return .accessibilityExtraLarge
            case "accessibility4": return .accessibilityExtraExtraLarge
            case "accessibility5": return .accessibilityExtraExtraExtraLarge
            default: return .large
            }
        }

        func windowReady(_ window: UIWindow) {
            self.window = window
            announceIfReady()
        }

        func clientConnected(_ descriptor: Int32) {
            client = descriptor
            announceIfReady()
        }

        func announceIfReady() {
            guard !announced, client >= 0, window != nil else { return }
            announced = true
            send(["event": "ready"])
        }

        func send(_ object: [String: Any]) {
            guard client >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(10)
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }

        func handle(_ object: [String: Any]) {
            switch object["cmd"] as? String {
            case "load": load(object)
            case "render": render(object)
            case "mouse": ack(mouse(object))
            case "scroll": ack(scroll(object))
            case "customAction": performCustomAction(object)
            case "elements": sendElements()
            case "key": ack(key(object))
            case "quit": exit(0)
            default: send(["event": "error", "message": "unknown command"])
            }
        }

        /// One reply per command. An empty route means the reply was already sent with more in it.
        func ack(_ route: String) {
            guard !route.isEmpty else { return }
            send(["event": "ack", "route": route])
        }

        // MARK: Input

        /// Where a press began, and how far the pointer has gone since: a press that travels is a
        /// scroll, one that does not is a tap at its release.
        var pressPoint: CGPoint?
        var lastPoint: CGPoint?
        var travelled = false
        static let tapSlop: CGFloat = 6
        /// What a press that travels is doing, decided at the first movement past the slop.
        enum DragMode { case scroll, slider(UISlider), swipe }
        var dragMode: DragMode?
        /// How far the pointer has pulled down at the top of a list, and whether that already refreshed.
        var pull: CGFloat = 0
        var pulledToRefresh = false
        static let pullThreshold: CGFloat = 70
        /// The button whose menu a tap opened: the next tap picks from it, or closes it.
        weak var openMenuButton: UIButton?

        func mouse(_ object: [String: Any]) -> String {
            guard let x = object["x"] as? Double, let y = object["y"] as? Double else { return "none" }
            let point = CGPoint(x: x, y: y)
            switch object["type"] as? String {
            case "down":
                pressPoint = point
                lastPoint = point
                travelled = false
                dragMode = nil
                pull = 0
                pulledToRefresh = false
                return "none"
            case "dragged":
                guard let start = pressPoint, let last = lastPoint else { return "none" }
                if !travelled {
                    guard hypot(point.x - start.x, point.y - start.y) >= PreviewHost.tapSlop else { return "none" }
                    travelled = true
                    dragMode = dragMode(from: start, to: point)
                }
                lastPoint = point
                switch dragMode {
                case .slider(let slider)?:
                    setSlider(slider, atWindowPoint: point)
                    return "slider"
                case .swipe?:
                    return "none"
                default:
                    // The content follows the pointer: a pointer moving up brings later content in.
                    return scroll(at: start, dx: last.x - point.x, dy: last.y - point.y, pulling: true)
                }
            case "up":
                let start = pressPoint
                let mode = dragMode
                let wasTap = start != nil && !travelled
                pressPoint = nil
                lastPoint = nil
                travelled = false
                dragMode = nil
                if wasTap { return tap(at: point) }
                if case .swipe? = mode, let start { return offerSwipeActions(startingAt: start) }
                return travelledUp(mode)
            default:
                return "none"
            }
        }

        /// A press that ended after travelling: it has already acted while it moved.
        func travelledUp(_ mode: DragMode?) -> String {
            if case .slider? = mode { return "slider" }
            return "drag"
        }

        /// What a press that has just started to travel is for. A slider keeps the pointer; a mostly
        /// horizontal press on an element with custom actions is a swipe; the rest scrolls.
        func dragMode(from start: CGPoint, to point: CGPoint) -> DragMode {
            if let slider = control(UISlider.self, at: start), slider.isEnabled { return .slider(slider) }
            if abs(point.x - start.x) > abs(point.y - start.y), customActionElement(at: start) != nil { return .swipe }
            return .scroll
        }

        // MARK: Controls with a value

        func control<T: UIView>(_ type: T.Type, at point: CGPoint) -> T? {
            var view = window?.hitTest(point, with: nil)
            while let current = view {
                if let match = current as? T { return match }
                view = current.superview
            }
            return nil
        }

        /// A slider's value from where the pointer is along its track, as a drag of the thumb would.
        func setSlider(_ slider: UISlider, atWindowPoint point: CGPoint) {
            let local = slider.convert(point, from: window)
            let track = slider.trackRect(forBounds: slider.bounds)
            guard track.width > 0 else { return }
            var fraction = (local.x - track.minX) / track.width
            if slider.effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
            fraction = min(max(fraction, 0), 1)
            let value = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
            guard value != slider.value else { return }
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }

        /// One step of a stepper: the trailing half adds, the leading half subtracts.
        func step(_ stepper: UIStepper, atWindowPoint point: CGPoint) {
            let local = stepper.convert(point, from: window)
            var increases = local.x >= stepper.bounds.midX
            if stepper.effectiveUserInterfaceLayoutDirection == .rightToLeft { increases.toggle() }
            let value = min(max(stepper.value + (increases ? stepper.stepValue : -stepper.stepValue),
                                stepper.minimumValue), stepper.maximumValue)
            guard value != stepper.value else { return }
            stepper.value = value
            stepper.sendActions(for: .valueChanged)
        }

        // MARK: Menus

        /// The `UIAction`s of a menu, submenus flattened, those that can be chosen.
        func actions(of menu: UIMenu) -> [UIAction] {
            menu.children.flatMap { child -> [UIAction] in
                if let action = child as? UIAction {
                    return action.attributes.contains(.disabled) ? [] : [action]
                }
                if let submenu = child as? UIMenu { return actions(of: submenu) }
                return []
            }
        }

        /// A tap while a menu is open: the item under the point is performed and the menu closed;
        /// anywhere else only closes it, as on a device.
        func tapInOpenMenu(_ button: UIButton, at point: CGPoint) -> String {
            openMenuButton = nil
            defer { button.contextMenuInteraction?.dismissMenu() }
            guard let menu = button.menu, let window else { return "menu" }
            let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
            let label = accessibilityElements(containing: screenPoint).first?.accessibilityLabel
            if let label, let action = actions(of: menu).first(where: { label == $0.title || label.hasPrefix($0.title + ",") }) {
                action.performWithSender(nil, target: nil)
            }
            return "menu"
        }

        // MARK: Swipe actions

        /// The smallest accessibility element holding the point that offers custom actions: what a
        /// swipe on a row reveals (`swipeActions`) and what `accessibilityAction` adds.
        func customActionElement(at point: CGPoint) -> NSObject? {
            guard let window else { return nil }
            let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
            return accessibilityElements(containing: screenPoint).first { !($0.accessibilityCustomActions ?? []).isEmpty }
        }

        /// The end of a swipe: the names of the actions go to Umbra, which asks which one to run.
        func offerSwipeActions(startingAt start: CGPoint) -> String {
            guard let element = customActionElement(at: start), let window else { return "none" }
            let names = (element.accessibilityCustomActions ?? []).map(\.name)
            let frame = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
            send(["event": "ack", "route": "actions", "actions": names, "x": Double(frame.midX), "y": Double(frame.midY)])
            return ""
        }

        func performCustomAction(_ object: [String: Any]) {
            guard let x = object["x"] as? Double, let y = object["y"] as? Double, let name = object["name"] as? String,
                  let element = customActionElement(at: CGPoint(x: x, y: y)),
                  let action = (element.accessibilityCustomActions ?? []).first(where: { $0.name == name }),
                  let handler = action.actionHandler else { return ack("none") }
            _ = handler(action)
            ack("customAction")
        }

        func tap(at point: CGPoint) -> String {
            guard let window else { return "none" }
            if let button = openMenuButton, button.window != nil { return tapInOpenMenu(button, at: point) }
            openMenuButton = nil
            if let field = textInput(at: point) {
                return field.becomeFirstResponder() ? "text" : "none"
            }
            if let slider = control(UISlider.self, at: point), slider.isEnabled {
                setSlider(slider, atWindowPoint: point)
                return "slider"
            }
            if let stepper = control(UIStepper.self, at: point), stepper.isEnabled {
                step(stepper, atWindowPoint: point)
                return "stepper"
            }
            // The tree is read for this tap only: it follows the hierarchy, not the document.
            let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
            if let smallest = accessibilityElements(containing: screenPoint).first, smallest.accessibilityActivate() {
                // A `Menu` or a menu-style `Picker` is a button with a `menu`: activating it opens the
                // menu in the frame, and the next tap chooses from it.
                if let button = smallest as? UIButton, button.menu != nil { openMenuButton = button }
                return "accessibility"
            }
            var view = window.hitTest(point, with: nil)
            while let current = view {
                if let control = current as? UIControl, control.isEnabled {
                    control.sendActions(for: .touchUpInside)
                    return "control"
                }
                view = current.superview
            }
            // The bars' own controls are UIKit's to change; their controllers' API is not.
            let label = accessibilityElements(containing: screenPoint).first?.accessibilityLabel
            return viewControllerRoute(label: label, at: point)
        }

        /// Every view controller below the window's root, presented ones included, topmost last.
        func viewControllers() -> [UIViewController] {
            var result: [UIViewController] = []
            func walk(_ controller: UIViewController) {
                result.append(controller)
                controller.children.forEach(walk)
                if let presented = controller.presentedViewController { walk(presented) }
            }
            if let root = window?.rootViewController { walk(root) }
            return result
        }

        /// A tab chosen by its title, or the back button of a navigation stack, through the
        /// controllers' public API. SwiftUI's `TabView` and `NavigationStack` follow both
        /// (measured in the spike).
        func viewControllerRoute(label: String?, at point: CGPoint) -> String {
            guard let window, let label, !label.isEmpty else { return "none" }
            let controllers = viewControllers()
            for case let tabs as UITabBarController in controllers {
                let titles = (tabs.tabBar.items ?? []).map { $0.title ?? "" }
                if let index = titles.firstIndex(of: label), tabs.selectedIndex != index {
                    tabs.selectedIndex = index
                    return "tab"
                }
            }
            for case let navigation as UINavigationController in controllers.reversed() where navigation.viewControllers.count > 1 {
                let bar = navigation.navigationBar
                guard !bar.isHidden, bar.convert(bar.bounds, to: window).contains(point) else { continue }
                let previous = navigation.viewControllers[navigation.viewControllers.count - 2]
                let titles = [previous.navigationItem.backButtonTitle, previous.navigationItem.title, previous.title, "Back"]
                if titles.contains(where: { $0 == label }) {
                    navigation.popViewController(animated: true)
                    return "back"
                }
            }
            return "none"
        }

        /// The labelled accessibility elements of the window, frames in window points.
        func sendElements() {
            guard let window else { return send(["event": "elements", "items": []]) }
            var found: [NSObject] = []
            var seen = Set<ObjectIdentifier>()
            collectAccessibilityElements(window, depth: 0, into: &found, seen: &seen)
            let items: [[String: Any]] = found.prefix(400).compactMap { element in
                guard let label = element.accessibilityLabel, !label.isEmpty else { return nil }
                let frame = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
                return ["label": label, "x": Double(frame.minX), "y": Double(frame.minY),
                        "width": Double(frame.width), "height": Double(frame.height)]
            }
            send(["event": "elements", "items": items])
        }

        /// The accessibility elements whose frame holds the point (screen coordinates), smallest first.
        func accessibilityElements(containing screenPoint: CGPoint) -> [NSObject] {
            guard let window else { return [] }
            var elements: [NSObject] = []
            var seen = Set<ObjectIdentifier>()
            collectAccessibilityElements(window, depth: 0, into: &elements, seen: &seen)
            return elements
                .filter { $0.accessibilityFrame.contains(screenPoint) }
                .sorted { $0.accessibilityFrame.width * $0.accessibilityFrame.height < $1.accessibilityFrame.width * $1.accessibilityFrame.height }
        }

        func collectAccessibilityElements(
            _ object: NSObject, depth: Int, into out: inout [NSObject], seen: inout Set<ObjectIdentifier>
        ) {
            guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement { out.append(object) }
            if let list = object.accessibilityElements {
                for case let element as NSObject in list {
                    collectAccessibilityElements(element, depth: depth + 1, into: &out, seen: &seen)
                }
                return
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collectAccessibilityElements(element, depth: depth + 1, into: &out, seen: &seen)
                    }
                }
            }
            if let view = object as? UIView {
                for subview in view.subviews {
                    collectAccessibilityElements(subview, depth: depth + 1, into: &out, seen: &seen)
                }
            }
        }

        /// The text field or text view under the point. SwiftUI's `TextField` is a `UITextField` that
        /// the hit test does not return (its hosting view does), so each ancestor's subtree is searched.
        func textInput(at point: CGPoint) -> UIView? {
            guard let window else { return nil }
            func search(_ view: UIView) -> UIView? {
                guard !view.isHidden, view.alpha > 0.01 else { return nil }
                for subview in view.subviews.reversed() {
                    if let found = search(subview) { return found }
                }
                if view is UITextField || view is UITextView,
                   view.canBecomeFirstResponder, view.convert(view.bounds, to: window).contains(point) {
                    return view
                }
                return nil
            }
            var ancestor = window.hitTest(point, with: nil)
            while let current = ancestor {
                if let found = search(current) { return found }
                ancestor = current.superview
            }
            return nil
        }

        func scroll(_ object: [String: Any]) -> String {
            guard let x = object["x"] as? Double, let y = object["y"] as? Double else { return "none" }
            let dx = CGFloat(object["dx"] as? Double ?? 0), dy = CGFloat(object["dy"] as? Double ?? 0)
            return scroll(at: CGPoint(x: x, y: y), dx: dx, dy: dy, pulling: false)
        }

        /// Moves the innermost scroll view under the point that can move that way, by points
        /// (positive `dy`: later content comes into view), as the macOS host does. A drag (`pulling`)
        /// that pulls down past the top of a list with a refresh control runs the refresh once.
        func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, pulling: Bool) -> String {
            guard let window, dx != 0 || dy != 0 else { return "none" }
            var refreshable: UIRefreshControl?
            var view = window.hitTest(point, with: nil)
            while let current = view {
                if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                    if move(scrollView, dx: dx, dy: dy) { return "scroll" }
                    let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
                    if refreshable == nil, atTop, let control = scrollView.refreshControl { refreshable = control }
                }
                view = current.superview
            }
            guard pulling, dy < 0, let refreshable else { return "none" }
            pull += -dy
            guard pull >= PreviewHost.pullThreshold, !pulledToRefresh else { return "none" }
            pulledToRefresh = true
            refreshable.sendActions(for: .valueChanged)
            return "refresh"
        }

        /// False when the scroll view cannot move that way (the next one out is tried).
        func move(_ scrollView: UIScrollView, dx: CGFloat, dy: CGFloat) -> Bool {
            let inset = scrollView.adjustedContentInset
            let minimum = CGPoint(x: -inset.left, y: -inset.top)
            let maximum = CGPoint(
                x: max(minimum.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
                y: max(minimum.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            )
            let old = scrollView.contentOffset
            let target = CGPoint(
                x: min(max(old.x + dx, minimum.x), maximum.x),
                y: min(max(old.y + dy, minimum.y), maximum.y)
            )
            guard target != old else { return false }
            scrollView.setContentOffset(target, animated: false)
            return true
        }

        func key(_ object: [String: Any]) -> String {
            let responder = UIResponder.currentFirstResponder()
            switch object["kind"] as? String {
            case "text":
                guard let text = object["text"] as? String, !text.isEmpty, let input = responder as? UIKeyInput else { return "none" }
                input.insertText(text)
                return "text"
            case "command":
                guard let name = object["selector"] as? String else { return "none" }
                return command(name, on: responder)
            case "action":
                guard let name = object["selector"] as? String else { return "none" }
                return UIApplication.shared.sendAction(Selector(name), to: nil, from: nil, for: nil) ? "action" : "none"
            default:
                return "none"
            }
        }

        /// The macOS host's editing selectors, as `UIKeyInput` and `UITextInput` express them.
        func command(_ name: String, on responder: UIResponder?) -> String {
            guard let responder else { return "none" }
            let input = responder as? UIKeyInput
            let text = responder as? UITextInput
            func moveCaret(by offset: Int) {
                guard let text, let range = text.selectedTextRange else { return }
                let from = offset < 0 ? range.start : range.end
                guard let position = text.position(from: from, offset: offset) else { return }
                text.selectedTextRange = text.textRange(from: position, to: position)
            }
            switch name {
            case "deleteBackward:":
                input?.deleteBackward()
            case "deleteForward:":
                guard let text, let end = text.selectedTextRange?.end,
                      let next = text.position(from: end, offset: 1) else { return "none" }
                text.selectedTextRange = text.textRange(from: end, to: next)
                input?.deleteBackward()
            case "insertNewline:":
                input?.insertText("\n")
            case "insertTab:":
                input?.insertText("\t")
            case "cancelOperation:":
                _ = responder.resignFirstResponder()
            case "moveLeft:":
                moveCaret(by: -1)
            case "moveRight:":
                moveCaret(by: 1)
            case "moveToBeginningOfLine:":
                if let text { text.selectedTextRange = text.textRange(from: text.beginningOfDocument, to: text.beginningOfDocument) }
            case "moveToEndOfLine:":
                if let text { text.selectedTextRange = text.textRange(from: text.endOfDocument, to: text.endOfDocument) }
            default:
                return "none"
            }
            return "text"
        }

        func load(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            func fail(_ message: String) {
                send(["event": "loaded", "generation": generation, "ok": false, "error": message])
            }
            guard let window else { return fail("no window") }
            openMenuButton = nil
            guard let path = object["dylib"] as? String else { return fail("no dylib") }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                return fail(String(cString: dlerror()))
            }
            guard let symbol = dlsym(handle, "umbra_preview_make_view") else {
                return fail("umbra_preview_make_view not found")
            }
            if !hasPreviewView {
                typealias Make = @convention(c) () -> UnsafeMutableRawPointer
                let make = unsafeBitCast(symbol, to: Make.self)
                let controller = Unmanaged<UIViewController>.fromOpaque(make()).takeRetainedValue()
                window.rootViewController = controller
                hasPreviewView = true
            } else {
                // The thunk replaced `UmbraPreview.content()`: the root creates it again.
                UmbraReload.shared.reset()
            }
            send(["event": "loaded", "generation": generation, "ok": true])
        }

        func render(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            func fail(_ message: String) {
                send(["event": "frame", "generation": generation, "ok": false, "error": message])
            }
            guard let window, hasPreviewView, let output = object["output"] as? String else { return fail("nothing loaded") }
            window.overrideUserInterfaceStyle = (object["scheme"] as? String) == "dark" ? .dark : .light
            let environment = UmbraEnvironment.shared
            let dynamicType = object["dynamicType"] as? String ?? "large"
            let locale = object["locale"] as? String ?? ""
            let rightToLeft = object["rightToLeft"] as? Bool ?? false
            // UIKit's own parts (the navigation bar, the keyboard) follow traits, not SwiftUI's
            // environment, so the text size and the layout direction go in as trait overrides.
            window.traitOverrides.preferredContentSizeCategory = PreviewHost.category(forDynamicType: dynamicType)
            window.traitOverrides.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            if environment.dynamicTypeSize != dynamicType { environment.dynamicTypeSize = dynamicType }
            if environment.localeIdentifier != locale { environment.localeIdentifier = locale }
            if environment.rightToLeft != rightToLeft { environment.rightToLeft = rightToLeft }
            // SwiftUI commits asynchronously: give it a few run-loop turns before drawing.
            for _ in 0..<3 {
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            let bounds = window.bounds
            let screenScale = window.traitCollection.displayScale
            var scale = max(CGFloat((object["scale"] as? Double) ?? 0), screenScale > 0 ? screenScale : 2)
            // Stay under about 36 megapixels, as the macOS host does.
            let area = bounds.width * bounds.height
            if area * scale * scale > 36_000_000 { scale = (36_000_000 / area).squareRoot() }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            guard let png = image.pngData() else { return fail("no image") }
            let temporary = output + ".tmp"
            do {
                try png.write(to: URL(fileURLWithPath: temporary))
                _ = rename(temporary, output)
            } catch {
                return fail("\(error)")
            }
            send(["event": "frame", "generation": generation, "ok": true, "path": output,
                  "width": Int(bounds.width * scale), "height": Int(bounds.height * scale),
                  "pointWidth": Double(bounds.width), "pointHeight": Double(bounds.height)])
        }
    }

    @objc(UmbraAppDelegate)
    final class AppDelegate: UIResponder, UIApplicationDelegate {}

    @objc(UmbraSceneDelegate)
    final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?

        func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
            guard let windowScene = scene as? UIWindowScene else { return }
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            self.window = window
            MainActor.assumeIsolated { PreviewHost.shared.windowReady(window) }
        }
    }

    // MARK: - Socket

    func serve(path: String) {
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else {
            FileHandle.standardError.write(Data("bind failed: \(String(cString: strerror(errno)))\n".utf8))
            exit(2)
        }
        Thread.detachNewThread {
            let connection = accept(server, nil, nil)
            if connection < 0 { exit(3) }
            DispatchQueue.main.async { MainActor.assumeIsolated { PreviewHost.shared.clientConnected(connection) } }
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(connection, &chunk, chunk.count)
                if count <= 0 { exit(0) } // Umbra went away.
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { PreviewHost.shared.handle(object) } }
                }
            }
        }
    }

    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--socket"), flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: host --socket <path>\n".utf8))
        exit(64)
    }
    serve(path: arguments[flag + 1])
    UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, "UmbraAppDelegate")
    """#
}
