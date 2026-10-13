// S3.0 spike: what can a host do about input from INSIDE the app, with public API only?
// A SwiftUI fixture (every control the plan names) and a probe that, for each one, takes the
// control's centre in window points and tries the routes the plan lists: hit-test + accessibility
// activation, UIControl.sendActions, scroll view offsets, UIKeyInput, accessibility custom actions.
// Observable state lives in `model`, so "did it work" is a read, not a guess. Results go to
// $UMBRA_RESULTS (text), frames to $UMBRA_OUT_DIR.
import UIKit
import SwiftUI
import Darwin

// MARK: - Fixture

final class Model: ObservableObject {
    @Published var taps = 0
    @Published var toggle = false
    @Published var sheet = false
    @Published var path: [Int] = []
    @Published var text = ""
    @Published var picked = "a"
    @Published var menuPicked = ""
    @Published var drags = 0
    @Published var longPresses = 0
    @Published var swipes = 0
    @Published var rowTaps = 0
    @Published var refreshes = 0
    @Published var toolbarTaps = 0
    @Published var sheetTaps = 0
    @Published var tab = 0
    @Published var gestureTaps = 0
    @Published var alert = false
    @Published var alertOK = 0
    var appeared = 0
    var frames: [String: CGRect] = [:]
}

let model = Model()

extension View {
    func probe(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frames[id] = $0 }
            .accessibilityIdentifier(id)
    }
}

struct Fixture: View {
    @ObservedObject var m = model

    var body: some View {
        TabView(selection: $m.tab) {
            NavigationStack(path: $m.path) {
                List {
                    Section("State") {
                        Text("taps \(m.taps) toggle \(m.toggle ? "on" : "off") text '\(m.text)' picked \(m.picked)")
                        Text("drags \(m.drags) long \(m.longPresses) swipes \(m.swipes) rows \(m.rowTaps)")
                    }
                    Section("Controls") {
                        Button("Tap me") { m.taps += 1 }.probe("tap")
                        Toggle("Switch", isOn: $m.toggle).probe("toggle")
                        Button("Show sheet") { m.sheet = true }.probe("sheet")
                        NavigationLink("Push detail", value: 1).probe("push")
                        TextField("Name", text: $m.text).probe("field")
                        Text("Drag me").padding(.vertical, 8)
                            .gesture(DragGesture().onChanged { _ in m.drags += 1 }).probe("drag")
                        Text("Long press me").padding(.vertical, 8)
                            .onLongPressGesture { m.longPresses += 1 }.probe("long")
                        Text("Swipe me")
                            .swipeActions { Button("Delete") { m.swipes += 1 } }.probe("swipe")
                        Text("Tap gesture").padding(.vertical, 8)
                            .onTapGesture { m.gestureTaps += 1 }.probe("gesture")
                        Button("Show alert") { m.alert = true }.probe("alert")
                        ScrollView(.horizontal) {
                            HStack { ForEach(0..<20, id: \.self) { Text("Chip \($0)").padding(8) } }
                        }.probe("chips")
                    }
                    Section("Menus") {
                        Picker("Pick", selection: $m.picked) {
                            Text("a").tag("a"); Text("b").tag("b"); Text("c").tag("c")
                        }.pickerStyle(.menu).probe("picker")
                        Menu("Menu") { Button("One") { m.menuPicked = "one" } }.probe("menu")
                    }
                    Section("Rows") {
                        ForEach(0..<50, id: \.self) { i in
                            Button("Row \(i)") { m.rowTaps = i + 1 }
                                .onAppear { m.appeared = max(m.appeared, i) }
                                .probe("row\(i)")
                        }
                    }
                }
                .alert("An alert", isPresented: $m.alert) { Button("OK") { m.alertOK += 1 } }
                .refreshable { m.refreshes += 1 }
                .navigationTitle("Input")
                .navigationDestination(for: Int.self) { _ in Text("Detail").probe("detail") }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add") { m.toolbarTaps += 1 }.probe("toolbar")
                    }
                }
                .sheet(isPresented: $m.sheet) {
                    VStack(spacing: 20) {
                        Text("A sheet")
                        Button("Close") { m.sheetTaps += 1; m.sheet = false }.probe("sheetClose")
                    }.padding()
                }
            }
            .tabItem { Label("Home", systemImage: "house") }.tag(0)
            Text("Second tab").tabItem { Label("Other", systemImage: "star") }.tag(1)
        }
    }
}

// MARK: - Helpers

extension UIResponder {
    private static weak var captured: UIResponder?
    @objc func umbraCaptureFirst() { UIResponder.captured = self }
    /// The public way to find the first responder: send an action to nil and see who receives it.
    static func current() -> UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(umbraCaptureFirst), to: nil, from: nil, for: nil)
        return captured
    }
}

@MainActor
final class Spike {
    let window: UIWindow
    let outDir: String
    var lines: [String] = []

    init(window: UIWindow, outDir: String) { self.window = window; self.outDir = outDir }

    func note(_ s: String) { lines.append(s); print(s) }

    func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func frameHash(_ name: String) -> Int {
        let r = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = r.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let png = image.pngData() else { return 0 }
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        return png.hashValue
    }

    func windowsAndViews() -> String {
        var windows = 0, views = 0
        func count(_ v: UIView) { views += 1; v.subviews.forEach(count) }
        for scene in UIApplication.shared.connectedScenes {
            guard let s = scene as? UIWindowScene else { continue }
            for w in s.windows { windows += 1; count(w) }
        }
        return "windows=\(windows) views=\(views) presented=\(window.rootViewController?.presentedViewController != nil)"
    }

    func chain(_ view: UIView?) -> String {
        var names: [String] = []
        var v = view
        while let c = v, names.count < 7 { names.append(String(describing: type(of: c))); v = c.superview }
        return names.joined(separator: " < ")
    }

    // MARK: Accessibility tree

    func collect(_ o: NSObject, _ depth: Int, _ out: inout [NSObject], _ seen: inout Set<ObjectIdentifier>) {
        guard depth < 60, seen.insert(ObjectIdentifier(o)).inserted else { return }
        if o.isAccessibilityElement { out.append(o) }
        if let list = o.accessibilityElements {
            for e in list { if let x = e as? NSObject { collect(x, depth + 1, &out, &seen) } }
        } else {
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let x = o.accessibilityElement(at: i) as? NSObject { collect(x, depth + 1, &out, &seen) } }
            }
            if let v = o as? UIView { for s in v.subviews { collect(s, depth + 1, &out, &seen) } }
        }
    }

    func elements() -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        collect(window, 0, &out, &seen)
        return out
    }

    /// Smallest accessibility element whose frame (screen points) holds the window point.
    func element(at p: CGPoint) -> NSObject? {
        let screenPoint = window.convert(p, to: window.screen.coordinateSpace)
        return elements()
            .filter { $0.accessibilityFrame.contains(screenPoint) }
            .min { $0.accessibilityFrame.width * $0.accessibilityFrame.height < $1.accessibilityFrame.width * $1.accessibilityFrame.height }
    }

    func describe(_ o: NSObject) -> String {
        let actions = (o.accessibilityCustomActions ?? []).map(\.name).joined(separator: "|")
        return "\(type(of: o)) label='\(o.accessibilityLabel ?? "")' id='\((o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "")' traits=\(o.accessibilityTraits.rawValue) actions=[\(actions)]"
    }

    // MARK: Routes

    func hit(_ p: CGPoint) -> UIView? { window.hitTest(p, with: nil) }

    func sendControl(at p: CGPoint) -> String {
        var v = hit(p)
        while let c = v {
            if let control = c as? UIControl {
                control.sendActions(for: .touchUpInside)
                return "sent .touchUpInside to \(type(of: control))"
            }
            v = c.superview
        }
        return "no UIControl above the hit view"
    }

    func innerScrollView(at p: CGPoint) -> UIScrollView? {
        var v = hit(p)
        while let c = v {
            if let s = c as? UIScrollView, s.isScrollEnabled { return s }
            v = c.superview
        }
        return nil
    }

    func waitChange(from before: String, _ read: () -> String) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < 0.9 {
            if read() != before { return Date().timeIntervalSince(start) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    struct Case {
        var id: String
        /// The point to act on, in window points; nil when the control is not on screen.
        var point: () -> CGPoint?
        var observe: () -> String
        var reset: () -> Void = {}
    }

    /// The centre of the first accessibility element with this label, in window points.
    func labelPoint(_ label: String, dx: CGFloat = 0.5) -> CGPoint? {
        guard let e = elements().first(where: { $0.accessibilityLabel == label }) else { return viewPoint(label, dx: dx) }
        let r = window.convert(e.accessibilityFrame, from: window.screen.coordinateSpace)
        return CGPoint(x: r.minX + r.width * dx, y: r.midY)
    }

    /// Without a tree: the centre of the first view whose own accessibility label matches.
    func viewPoint(_ label: String, dx: CGFloat = 0.5) -> CGPoint? {
        var found: UIView?
        func search(_ v: UIView) {
            if found == nil, v.accessibilityLabel == label, !v.isHidden, v.window != nil { found = v }
            v.subviews.forEach(search)
        }
        search(window)
        guard let v = found else { return nil }
        let r = v.convert(v.bounds, to: window)
        return CGPoint(x: r.minX + r.width * dx, y: r.midY)
    }

    func modelPoint(_ id: String, dx: CGFloat = 0.5) -> CGPoint? {
        guard let f = model.frames[id], f.width > 0 else { return nil }
        return CGPoint(x: f.minX + f.width * dx, y: f.midY)
    }

    func runCase(_ c: Case, strategies: [String] = ["ax-activate", "uicontrol"]) async {
        guard let p = c.point() else { return note("\(c.id): not on screen / no point") }
        note("\(c.id) at (\(Int(p.x)),\(Int(p.y))) hit: \(chain(hit(p)))")
        if let e = element(at: p) { note("  AX element: \(describe(e))") } else { note("  AX element: none found at the point") }
        for strategy in strategies {
            c.reset(); await settle(0.7)
            guard let p = c.point() else { note("  \(strategy): control gone after reset"); continue }
            let before = c.observe()
            var detail = ""
            switch strategy {
            case "ax-activate":
                if let e = element(at: p) { detail = "accessibilityActivate() = \(e.accessibilityActivate())" } else { detail = "no element" }
            default:
                detail = sendControl(at: p)
            }
            let t = await waitChange(from: before, c.observe)
            let after = c.observe()
            note("  \(strategy): \(detail); changed=\(t != nil) [\(before)] -> [\(after)]\(t.map { String(format: " in %.0f ms", $0 * 1000) } ?? "")")
        }
    }

    // MARK: The probe

    func scrollToTop() async {
        if let s = innerScrollView(at: CGPoint(x: 100, y: 400)) {
            s.setContentOffset(CGPoint(x: 0, y: -s.adjustedContentInset.top), animated: false)
        }
        await settle(0.5)
    }

    func run() async {
        let delay = Double(ProcessInfo.processInfo.environment["UMBRA_START_DELAY"] ?? "") ?? 1.0
        await settle(delay)
        note("== launch: \(windowsAndViews()) window=\(window.bounds.size) scale=\(window.traitCollection.displayScale)")
        let walkStart = Date()
        let all = elements()
        note(String(format: "== tree walk: %.1f ms", Date().timeIntervalSince(walkStart) * 1000))
        note("== accessibility tree: \(all.count) elements; hosting view elementCount=\(window.rootViewController?.view.accessibilityElementCount() ?? -1)")
        for e in all.prefix(40) { note("   \(describe(e)) frame=\(e.accessibilityFrame)") }
        _ = frameHash("00-launch")

        let m = model
        await runCase(.init(id: "button", point: { self.modelPoint("tap") }, observe: { "taps=\(m.taps)" }))
        await runCase(.init(id: "toggle (label side)", point: { self.modelPoint("toggle", dx: 0.2) }, observe: { "on=\(m.toggle)" }))
        await runCase(.init(id: "toggle (switch)", point: { self.modelPoint("toggle", dx: 0.92) }, observe: { "on=\(m.toggle)" }))
        await runCase(.init(id: "toolbar button", point: { self.modelPoint("toolbar") }, observe: { "n=\(m.toolbarTaps)" }))

        // Gestures without a tap equivalent.
        await runCase(.init(id: "drag gesture", point: { self.modelPoint("drag") }, observe: { "drags=\(m.drags)" }))
        await runCase(.init(id: "long press", point: { self.modelPoint("long") }, observe: { "long=\(m.longPresses)" }))
        await runCase(.init(id: "onTapGesture", point: { self.modelPoint("gesture") }, observe: { "gestureTaps=\(m.gestureTaps)" }))
        if let p = modelPoint("chips"), let scroll = innerScrollView(at: p) {
            let x0 = scroll.contentOffset.x
            scroll.setContentOffset(CGPoint(x: x0 + 200, y: scroll.contentOffset.y), animated: false)
            await settle(0.3)
            note("horizontal scroll under the chips: \(type(of: scroll)) x \(x0) -> \(scroll.contentOffset.x), contentSize \(scroll.contentSize.width)")
        } else { note("horizontal scroll: no scroll view under the chips (or not on screen)") }
        if let p = modelPoint("swipe"), let e = element(at: p) {
            let actions = e.accessibilityCustomActions ?? []
            note("swipe row: custom actions = \(actions.map(\.name))")
            if let a = actions.first {
                let before = m.swipes
                let handled = a.actionHandler?(a) ?? false
                await settle(0.4)
                note("  invoked '\(a.name)': handler=\(handled) swipes \(before) -> \(m.swipes)")
            }
        } else { note("swipe row: no AX element / not on screen") }

        await scrollProbes()
        await textProbes()
        await touchProbes()
        await scrollToTop()

        // Sheet: open by activation, look at the frame, tap inside, then the ways to close it.
        let beforeSheet = frameHash("10-before-sheet")
        await runCase(.init(id: "sheet presenter", point: { self.modelPoint("sheet") },
                            observe: { "sheet=\(m.sheet) \(self.windowsAndViews())" }, reset: { m.sheet = false }),
                      strategies: ["ax-activate"])
        await settle(0.8)
        if !m.sheet { m.sheet = true; await settle(1.0) }
        let withSheet = frameHash("11-sheet-open")
        note("== sheet frame differs from no-sheet frame: \(withSheet != beforeSheet); \(windowsAndViews())")
        await runCase(.init(id: "button inside the sheet", point: { self.modelPoint("sheetClose") },
                            observe: { "closes=\(m.sheetTaps) open=\(m.sheet)" }, reset: { if !m.sheet { m.sheet = true } }),
                      strategies: ["ax-activate"])
        await settle(0.8)
        m.sheet = true; await settle(1.0)
        let top = window.rootViewController?.presentedViewController
        let esc = top?.view.accessibilityPerformEscape() ?? false
        await settle(0.8)
        note("== accessibilityPerformEscape on the sheet's view: \(esc), sheet now \(m.sheet)")
        if m.sheet { top?.dismiss(animated: false); await settle(0.6); note("   presentedViewController.dismiss(animated:) -> sheet=\(m.sheet)") }
        m.sheet = false; await settle(0.8)

        // Navigation: push by activation, find the way back through the tree.
        await runCase(.init(id: "navigation link", point: { self.modelPoint("push") },
                            observe: { "depth=\(m.path.count)" }, reset: { m.path = [] }),
                      strategies: ["ax-activate"])
        await settle(1.0)
        note("== after the push: \(windowsAndViews())")
        for e in elements().prefix(12) { note("   \(describe(e)) frame=\(e.accessibilityFrame)") }
        _ = frameHash("40-pushed")
        // Ways back: the back button element, the control under it, the escape gesture along the responder chain.
        if let back = elements().first(where: { String(describing: type(of: $0)).contains("BackButton") }) {
            let r = window.convert(back.accessibilityFrame, from: window.screen.coordinateSpace)
            let q = CGPoint(x: r.midX, y: r.midY)
            note("   back element \(describe(back)); activate = \(back.accessibilityActivate()); depth \(m.path.count)")
            note("   hit at the back button: \(chain(hit(q)))")
            note("   \(sendControl(at: q)); depth \(m.path.count)")
            await settle(0.6)
            note("   depth after sendActions: \(m.path.count)")
        } else { note("   no back button element found") }
        if m.path.count > 0 {
            var responder: UIResponder? = hit(CGPoint(x: 220, y: 500))
            var steps: [String] = []
            var handled = false
            while let r = responder, !handled {
                if r.accessibilityPerformEscape() { handled = true; steps.append("\(type(of: r)) handled") } else { steps.append(String(describing: type(of: r))) }
                responder = r.next
            }
            await settle(1.0)
            note("   accessibilityPerformEscape along the responder chain: handled=\(handled) depth \(m.path.count); chain: \(steps.prefix(10).joined(separator: " > "))")
        }
        m.path = []; await settle(1.2)

        // Tab bar: with a tree the items are elements; without one they are UIKit controls.
        await runCase(.init(id: "tab bar item (Other)", point: { self.labelPoint("Other") }, observe: { "tab=\(m.tab)" }, reset: { m.tab = 0 }))
        m.tab = 0; await settle(0.8)

        // Alert: presented by activation; is its button reachable, and is it in the frame?
        await scrollToTop()
        await runCase(.init(id: "alert presenter", point: { self.modelPoint("alert") ?? self.labelPoint("Show alert") },
                            observe: { "alert=\(m.alert)" }, reset: { m.alert = false }), strategies: ["ax-activate"])
        await settle(1.0)
        _ = frameHash("50-alert")
        note("== alert open: \(windowsAndViews()); AX elements now: \(elements().map { $0.accessibilityLabel ?? "?" }.prefix(8))")
        if let ok = elements().first(where: { $0.accessibilityLabel == "OK" }) {
            note("   OK button: \(describe(ok)); activate = \(ok.accessibilityActivate())")
            // Walk up the views asking each to activate, then try the control under the point.
            var v = ok as? UIView
            var steps: [String] = []
            while let c = v {
                let r = c.accessibilityActivate(); steps.append("\(type(of: c))=\(r)")
                if r { break }
                v = c.superview
            }
            note("   activation up the superviews: \(steps.prefix(8).joined(separator: " > ")); alertOK=\(m.alertOK)")
            let r = window.convert(ok.accessibilityFrame, from: window.screen.coordinateSpace)
            let q = CGPoint(x: r.midX, y: r.midY)
            note("   hit at OK: \(chain(hit(q)))")
            note("   \(sendControl(at: q)); alertOK=\(m.alertOK) alert=\(m.alert)")
            let alertVC = window.rootViewController?.presentedViewController as? UIAlertController
            note("   presented UIAlertController: \(alertVC != nil) actions=\(alertVC?.actions.map { $0.title ?? "?" } ?? [])")
            await settle(0.6)
            note("   alertOK=\(m.alertOK) alert=\(m.alert)")
        } else { note("   no OK element in the tree") }
        if m.alert { m.alert = false; await settle(0.6) }

        // Menus last: an open menu cannot be dismissed without a tap.
        if let s = innerScrollView(at: CGPoint(x: 100, y: 400)) {
            s.setContentOffset(CGPoint(x: 0, y: 200), animated: false); await settle(0.6)
        }
        if let p = labelPoint("Chip 0"), let h = innerScrollView(at: p) {
            let x0 = h.contentOffset.x
            let horizontal = h.contentSize.width > h.bounds.width + 1 && h.contentSize.height <= h.bounds.height + 1
            h.setContentOffset(CGPoint(x: x0 + 200, y: h.contentOffset.y), animated: false)
            await settle(0.4)
            note("== horizontal scroll at the chips: \(type(of: h)) horizontal-only=\(horizontal) x \(x0) -> \(h.contentOffset.x) contentSize=\(h.contentSize)")
        } else { note("== horizontal scroll: chips not found on screen") }
        await runCase(.init(id: "menu picker", point: { self.labelPoint("Pick") ?? self.labelPoint("Pick, a") }, observe: { self.windowsAndViews() }),
                      strategies: ["ax-activate"])
        await settle(0.8)
        _ = frameHash("90-after-picker")
        let labels = elements().compactMap { $0.accessibilityLabel }.filter { ["a", "b", "c"].contains($0) }
        note("== menu open: item labels in the tree: \(labels)")
        if let item = elements().first(where: { $0.accessibilityLabel == "b" }) {
            note("   item 'b': \(describe(item)); activate = \(item.accessibilityActivate())")
            await settle(0.8)
            note("   picked = \(m.picked)")
            if m.picked != "b" {
                let r = window.convert(item.accessibilityFrame, from: window.screen.coordinateSpace)
                let q = CGPoint(x: r.midX, y: r.midY)
                note("   hit at 'b': \(chain(hit(q)))")
                note("   \(sendControl(at: q)); picked = \(m.picked)")
                await settle(0.6)
                note("   picked = \(m.picked)")
            }
        }
        note("== done")
        try? lines.joined(separator: "\n").write(toFile: "\(outDir)/results.txt", atomically: true, encoding: .utf8)
        try? "done".write(toFile: "\(outDir)/done", atomically: true, encoding: .utf8)
    }

    func scrollProbes() async {
        let p = CGPoint(x: 100, y: 400)
        guard let scroll = innerScrollView(at: p) else { return note("== scroll: no UIScrollView above the hit view") }
        note("== scroll: innermost scroll view \(type(of: scroll)) offset=\(scroll.contentOffset) size=\(scroll.contentSize) bounds=\(scroll.bounds.size) inset=\(scroll.adjustedContentInset) refreshControl=\(scroll.refreshControl != nil)")
        let appearedBefore = model.appeared
        let hashBefore = frameHash("20-before-scroll")
        let old = scroll.contentOffset
        let minY = -scroll.adjustedContentInset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let target = CGPoint(x: old.x, y: min(max(old.y + 900, minY), maxY))
        scroll.setContentOffset(target, animated: false)
        await settle(0.5)
        let hashAfter = frameHash("21-after-scroll")
        note("   setContentOffset(+900 clamped to \(target.y)): offset \(old.y) -> \(scroll.contentOffset.y); rows that appeared \(appearedBefore) -> \(model.appeared); frame changed=\(hashAfter != hashBefore)")
        // A row that scrolled into view: can it be tapped by point?
        let visibleRow = (0..<50).first { i in labelPoint("Row \(i)").map { $0.y > 200 && $0.y < 800 } ?? false }
        if let i = visibleRow, let q = labelPoint("Row \(i)") {
            let before = model.rowTaps
            if let e = element(at: q) { _ = e.accessibilityActivate() } else { note("   no AX element at row \(i)") }
            await settle(0.3)
            note("   tap of row \(i) by AX: rows \(before) -> \(model.rowTaps)")
        } else { note("   no row label found on screen after the scroll") }
        // The accessibility route to scrolling.
        scroll.setContentOffset(CGPoint(x: old.x, y: minY), animated: false); await settle(0.4)
        let y0 = scroll.contentOffset.y
        let ok = scroll.accessibilityScroll(.down)
        await settle(0.8)
        note("   accessibilityScroll(.down) on the scroll view: \(ok), offset \(y0) -> \(scroll.contentOffset.y)")
        // Pull to refresh.
        scroll.setContentOffset(CGPoint(x: old.x, y: minY), animated: false); await settle(0.4)
        let refreshBefore = model.refreshes
        if let rc = scroll.refreshControl {
            rc.sendActions(for: .valueChanged)
            await settle(0.8)
            note("   refreshControl.sendActions(.valueChanged): refreshes \(refreshBefore) -> \(model.refreshes)")
        } else { note("   no UIRefreshControl on the list's scroll view") }
        scroll.setContentOffset(CGPoint(x: old.x, y: minY), animated: false); await settle(0.4)
    }

    func textProbes() async {
        guard let p = modelPoint("field") else { return note("== text: the field is not on screen") }
        model.text = ""
        note("== text: first responder before: \(String(describing: UIResponder.current().map { type(of: $0) }))")
        // Route 1: AX activation of the field, then ask who is first responder.
        if let e = element(at: p) { note("   field AX activate = \(e.accessibilityActivate())") }
        await settle(0.8)
        var responder = UIResponder.current()
        note("   first responder after AX activation: \(String(describing: responder.map { type(of: $0) }))")
        // Route 2: find the UITextField under the point and make it first responder.
        if responder == nil {
            var v = hit(p)
            var found: UIView?
            func search(_ view: UIView) { if view is UITextField || view is UITextView { found = found ?? view }; view.subviews.forEach(search) }
            while let c = v, found == nil { search(c); v = c.superview }
            if found == nil, let root = window.rootViewController?.view { search(root) }
            if let field = found {
                note("   hit-tested subtree holds \(type(of: field)); becomeFirstResponder() = \(field.becomeFirstResponder())")
                await settle(0.6)
                responder = UIResponder.current()
                note("   first responder now: \(String(describing: responder.map { type(of: $0) }))")
            } else { note("   no UITextField/UITextView found near the point") }
        }
        if let input = responder as? UIKeyInput {
            input.insertText("hello")
            await settle(0.3)
            note("   insertText(\"hello\") -> model.text='\(model.text)'")
            input.deleteBackward(); input.deleteBackward()
            await settle(0.3)
            note("   deleteBackward x2 -> model.text='\(model.text)'")
            input.insertText("\n")
            await settle(0.4)
            note("   insertText(\"\\n\") -> first responder: \(String(describing: UIResponder.current().map { type(of: $0) }))")
        } else {
            note("   no UIKeyInput first responder: text cannot be typed")
        }
        // Is the software keyboard in the capture?
        if let field = responder as? UIView { _ = field.becomeFirstResponder() }
        await settle(0.8)
        _ = frameHash("30-keyboard")
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.count }.reduce(0, +)
        note("   windows while a field is focused: \(screen) (the keyboard, when shown, is a window of its own; see 30-keyboard.png)")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        await settle(0.4)
    }

    func touchProbes() async {
        note("== a touch of one's own")
        let t = UITouch()
        note("   UITouch() constructs; phase=\(t.phase.rawValue) window=\(String(describing: t.window)) view=\(String(describing: t.view)) tapCount=\(t.tapCount)")
        note("   its phase, window, view and location have no public setters; UIEvent has no public initialiser for touches, so there is no public way to sendEvent one")
    }
}

// MARK: - App

@main
@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {}

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = UIHostingController(rootView: Fixture())
        w.makeKeyAndVisible()
        window = w
        let outDir = ProcessInfo.processInfo.environment["UMBRA_OUT_DIR"] ?? "/tmp"
        let spike = Spike(window: w, outDir: outDir)
        Task { @MainActor in await spike.run() }
    }
}
