/// The source of `UmbraPreviewHost`, the process that shows a preview.
///
/// It is shipped as text because Umbra compiles it against each project (one `swiftc` call, with
/// the project's object files, so the project's code is in the process the preview thunks are
/// loaded into) and a string needs no resource bundle in `swift run Umbra`. The host knows nothing
/// about the project: it loads a thunk dylib, asks it for the view (`umbra_preview_make_view`),
/// puts the view in an offscreen window and answers JSON-line commands on a Unix socket.
///
/// Commands (one JSON object per line):
/// - `{"cmd":"load","dylib":"/p/thunk.dylib","generation":1}` → `{"event":"loaded","generation":1,"ok":true}`;
///   the first thunk creates the view; a later one has replaced `UmbraPreview.content()`, and
///   `UmbraReload.reset()` makes the root create it again
/// - `{"cmd":"render","generation":1,"width":400,"height":300,"scale":2,"scheme":"dark","output":"/p/f.png"}`
///   (optional `dynamicType`: a `DynamicTypeSize` case name, `locale`: an identifier, `rightToLeft`: a Bool,
///   `fit`: a Bool, true when the window should take the view's own ideal size, not `width` and `height`;
///   `safeTop` and `safeBottom`: points the content keeps clear at the top and bottom, default 0)
///   → `{"event":"frame","generation":1,"path":"/p/f.png","width":800,"height":600,"pointWidth":400,"pointHeight":300}`
///   (`width` and `height` are pixels, `pointWidth` and `pointHeight` the window's size in points)
/// - `{"cmd":"mouse","type":"down|up|dragged|moved","x":10,"y":20}` → `{"event":"ack"}`
/// - `{"cmd":"scroll","x":10,"y":20,"dx":0,"dy":120}` scrolls the innermost scroll view under the
///   point that can move that way, by points (positive `dy`: later content comes into view)
/// - `{"cmd":"key","kind":"text","text":"ab"}` types into the focused view;
///   `{"cmd":"key","kind":"command","selector":"deleteBackward:"}` performs an editing command on it;
///   `{"cmd":"key","kind":"action","selector":"copy:"}` sends an action down the responder chain
/// - `{"cmd":"quit"}`
///
/// Behaviour measured in `Tools/PreviewSpike` and recorded in `docs/SWIFTUI_PREVIEW_PLAN.md` (P0):
/// the capture goes through `CALayer.render(in:)` into a flipped context, the window gets an explicit
/// appearance, and mouse input is synthesized with `NSWindow.sendEvent`.
///
/// A sheet or an alert is a window of its own, so the window's layer does not hold it, and AppKit
/// pulls the window it belongs to onto the screen. The host puts the window back offscreen each time
/// that happens (the sheet follows it), draws the sheets over the frame itself (the window dimmed,
/// the sheet with its shadow), and sends input to the topmost sheet while there is one, as the
/// window server does. Popovers and menus are not handled (not measured).
public enum SwiftPreviewHostSource {
    public static let fileName = "main.swift"

    public static let text = #"""
    import AppKit
    import Darwin
    import Foundation
    import SwiftUI
    import UmbraPreviewSupport

    @MainActor
    final class PreviewHost {
        let window: NSWindow
        var client: Int32 = -1
        var size = NSSize(width: 400, height: 300)
        var hasPreviewView = false

        /// Where the window lives: far from every screen.
        static let parked = NSPoint(x: -20000, y: -20000)

        init() {
            window = NSWindow(contentRect: NSRect(origin: PreviewHost.parked, size: NSSize(width: 400, height: 300)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.orderFrontRegardless()
            // Showing a sheet makes AppKit move its parent onto a screen (measured: it happens many
            // times while the sheet comes up). Moving the window back takes the sheet with it.
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { self.parkIfNeeded() }
            }
        }

        func parkIfNeeded() {
            let frame = window.frame
            guard frame.maxX > -10000 || frame.maxY > -10000 else { return }
            window.setFrameOrigin(PreviewHost.parked)
        }

        // MARK: Sheets

        /// The sheets on the window, outermost first (an alert is one too).
        func attachedSheets() -> [NSWindow] {
            var sheets: [NSWindow] = []
            var current = window
            while let sheet = current.attachedSheet, !sheets.contains(where: { $0 === sheet }) {
                sheets.append(sheet)
                current = sheet
            }
            return sheets
        }

        /// Where a sheet sits over the frame, in points with y down. AppKit places it relative to the
        /// window, so the two frames say where, whatever the window's own position.
        func sheetRect(_ sheet: NSWindow) -> NSRect {
            let parent = window.frame, frame = sheet.frame
            return NSRect(x: frame.minX - parent.minX, y: parent.maxY - frame.maxY, width: frame.width, height: frame.height)
        }

        /// A sheet is a window of its own and does not take the preview window's explicit appearance.
        func syncSheetAppearance() {
            for sheet in attachedSheets() where sheet.appearance !== window.appearance {
                sheet.appearance = window.appearance
            }
        }

        /// Draws what the screen would show over the window's frame: the window dimmed, then each
        /// sheet with a shadow. `context` is the frame's, in points with y down.
        func drawSheets(in context: CGContext) {
            let sheets = attachedSheets()
            guard !sheets.isEmpty else { return }
            let scale = context.ctm.a
            context.saveGState()
            context.setFillColor(CGColor(gray: 0, alpha: 0.18))
            context.fill(CGRect(origin: .zero, size: size))
            context.restoreGState()
            for sheet in sheets {
                guard let content = sheet.contentView else { continue }
                content.wantsLayer = true
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                guard let layer = content.layer else { continue }
                let rect = sheetRect(sheet)
                let shape = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
                var background = NSColor.windowBackgroundColor.cgColor
                (sheet.appearance ?? window.effectiveAppearance).performAsCurrentDrawingAppearance {
                    background = NSColor.windowBackgroundColor.cgColor
                }
                // The shadow is not part of any layer: a filled shape casts it, the content goes over it.
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 24 * scale,
                                  color: CGColor(gray: 0, alpha: 0.35))
                context.setFillColor(background)
                context.addPath(shape)
                context.fillPath()
                context.restoreGState()
                context.saveGState()
                context.addPath(shape)
                context.clip()
                context.translateBy(x: rect.minX, y: rect.minY)
                // A flipped view's layer is drawn upright in this context (as the window's is); an
                // unflipped one, such as an alert's, needs the other orientation.
                if !content.isFlipped {
                    context.translateBy(x: 0, y: rect.height)
                    context.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context)
                context.restoreGState()
            }
        }

        /// Where input at a point of the frame goes: the topmost sheet while there is one (the window
        /// ignores input then, as on screen), else the window. `point` is in the view's own coordinates.
        func inputTarget(x: Double, y: Double) -> (window: NSWindow, view: NSView, point: NSPoint)? {
            guard let root = window.contentView else { return nil }
            guard let sheet = attachedSheets().last, let view = sheet.contentView else {
                return (window, root, NSPoint(x: x, y: y))
            }
            let rect = sheetRect(sheet)
            let down = y - rect.minY
            return (sheet, view, NSPoint(x: x - rect.minX, y: view.isFlipped ? down : rect.height - down))
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
            case "mouse": mouse(object)
            case "scroll": scroll(object)
            case "key": key(object)
            case "quit": exit(0)
            default: send(["event": "error", "message": "unknown command"])
            }
        }

        func load(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            func fail(_ message: String) {
                send(["event": "loaded", "generation": generation, "ok": false, "error": message])
            }
            guard let path = object["dylib"] as? String else { return fail("no dylib") }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                return fail(String(cString: dlerror()))
            }
            guard let symbol = dlsym(handle, "umbra_preview_make_view") else {
                return fail("umbra_preview_make_view not found")
            }
            if window.contentView == nil || !hasPreviewView {
                typealias Make = @convention(c) () -> UnsafeMutableRawPointer
                let make = unsafeBitCast(symbol, to: Make.self)
                let view = Unmanaged<NSView>.fromOpaque(make()).takeRetainedValue()
                view.wantsLayer = true
                window.contentView = view
                window.setContentSize(size)
                hasPreviewView = true
            } else {
                // The thunk replaced `UmbraPreview.content()`: the root creates it again.
                UmbraReload.shared.reset()
            }
            send(["event": "loaded", "generation": generation, "ok": true])
        }

        func render(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            if let width = object["width"] as? Double, let height = object["height"] as? Double, width > 0, height > 0 {
                size = NSSize(width: width, height: height)
            }
            window.appearance = NSAppearance(named: (object["scheme"] as? String) == "dark" ? .darkAqua : .aqua)
            syncSheetAppearance()
            let environment = UmbraEnvironment.shared
            let dynamicType = object["dynamicType"] as? String ?? "large"
            let locale = object["locale"] as? String ?? ""
            let rightToLeft = object["rightToLeft"] as? Bool ?? false
            if environment.dynamicTypeSize != dynamicType { environment.dynamicTypeSize = dynamicType }
            if environment.localeIdentifier != locale { environment.localeIdentifier = locale }
            if environment.rightToLeft != rightToLeft { environment.rightToLeft = rightToLeft }
            let safeTop = object["safeTop"] as? Double ?? 0
            let safeBottom = object["safeBottom"] as? Double ?? 0
            if environment.safeAreaTop != safeTop { environment.safeAreaTop = safeTop }
            if environment.safeAreaBottom != safeBottom { environment.safeAreaBottom = safeBottom }
            if (object["fit"] as? Bool) == true, let view = window.contentView {
                // The view's own ideal size (`.frame(width:height:)`, text, images). The thunk turns the
                // hosting view's sizing off (the window decides, and `fittingSize` is zero then), so the
                // ideal size is switched on for this measurement only (measured: the window keeps its size).
                let hosting = view as? NSHostingView<AnyView>
                let previous = hosting?.sizingOptions
                hosting?.sizingOptions = [.intrinsicContentSize]
                view.layoutSubtreeIfNeeded()
                let ideal = view.fittingSize
                if let hosting, let previous { hosting.sizingOptions = previous }
                if ideal.width > 0, ideal.height > 0 {
                    size = NSSize(width: min(max(ideal.width.rounded(.up), 44), 4096),
                                  height: min(max(ideal.height.rounded(.up), 44), 4096))
                }
            }
            window.setContentSize(size)
            guard let view = window.contentView, let output = object["output"] as? String else {
                return send(["event": "frame", "generation": generation, "ok": false, "error": "nothing loaded"])
            }
            // SwiftUI commits asynchronously: give it a few run-loop turns before reading the layer.
            for _ in 0..<3 {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            var scale = (object["scale"] as? Double).map { CGFloat($0) } ?? window.backingScaleFactor
            // A large window at a high scale is a large bitmap: stay under about 36 megapixels.
            let area = size.width * size.height
            if area * scale * scale > 36_000_000 { scale = (36_000_000 / area).squareRoot() }
            let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
            guard let layer = view.layer,
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return send(["event": "frame", "generation": generation, "ok": false, "error": "no layer"]) }
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)
            drawSheets(in: context)
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { return send(["event": "frame", "generation": generation, "ok": false, "error": "no image"]) }
            let temporary = output + ".tmp"
            do {
                try png.write(to: URL(fileURLWithPath: temporary))
                _ = rename(temporary, output)
            } catch {
                return send(["event": "frame", "generation": generation, "ok": false, "error": "\(error)"])
            }
            send(["event": "frame", "generation": generation, "ok": true, "path": output,
                  "width": pixelWidth, "height": pixelHeight,
                  "pointWidth": Double(size.width), "pointHeight": Double(size.height)])
        }

        func scroll(_ object: [String: Any]) {
            defer { send(["event": "ack"]) }
            guard let x = object["x"] as? Double, let y = object["y"] as? Double,
                  let target = inputTarget(x: x, y: y) else { return }
            let view = target.view
            let dx = CGFloat(object["dx"] as? Double ?? 0), dy = CGFloat(object["dy"] as? Double ?? 0)
            guard dx != 0 || dy != 0 else { return }
            let point = view.convert(target.point, to: view.superview)
            var candidate = view.hitTest(point)
            while let current = candidate {
                if let scrollView = current as? NSScrollView, scroll(scrollView, dx: dx, dy: dy) { return }
                candidate = current.superview
            }
        }

        /// Moves one scroll view; false when it cannot move that way (the next one out is tried).
        func scroll(_ scrollView: NSScrollView, dx: CGFloat, dy: CGFloat) -> Bool {
            let clip = scrollView.contentView
            let flipped = scrollView.documentView?.isFlipped ?? true
            let sign: CGFloat = flipped ? 1 : -1
            let old = clip.bounds.origin
            var target = NSRect(origin: NSPoint(x: old.x + dx, y: old.y + dy * sign), size: clip.bounds.size)
            target.origin = clip.constrainBoundsRect(target).origin
            guard target.origin != old else { return false }
            clip.scroll(to: target.origin)
            scrollView.reflectScrolledClipView(clip)
            return true
        }

        func key(_ object: [String: Any]) {
            defer { send(["event": "ack"]) }
            // Keys go to the topmost sheet while there is one, as on screen.
            let active = attachedSheets().last ?? window
            let responder = active.firstResponder
            switch object["kind"] as? String {
            case "text":
                guard let text = object["text"] as? String, !text.isEmpty else { return }
                if let client = responder as? NSTextInputClient {
                    client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else if let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: active.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: 0
                ) {
                    active.sendEvent(event)
                }
            case "command":
                guard let name = object["selector"] as? String else { return }
                if let responder { responder.doCommand(by: Selector(name)) }
            case "action":
                guard let name = object["selector"] as? String else { return }
                NSApp.sendAction(Selector(name), to: responder, from: nil)
            default:
                break
            }
        }

        func mouse(_ object: [String: Any]) {
            guard let x = object["x"] as? Double, let y = object["y"] as? Double,
                  let target = inputTarget(x: x, y: y) else {
                return send(["event": "ack"])
            }
            let type: NSEvent.EventType
            switch object["type"] as? String {
            case "down": type = .leftMouseDown
            case "up": type = .leftMouseUp
            case "dragged": type = .leftMouseDragged
            default: type = .mouseMoved
            }
            let location = target.view.convert(target.point, to: nil)
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                target.window.sendEvent(event)
            }
            send(["event": "ack"])
        }
    }

    // MARK: - Socket

    func serve(path: String, host: PreviewHost) {
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
            DispatchQueue.main.async { MainActor.assumeIsolated { host.client = connection; host.send(["event": "ready"]) } }
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
                    DispatchQueue.main.async { MainActor.assumeIsolated { host.handle(object) } }
                }
            }
        }
    }

    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--socket"), flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: host --socket <path>\n".utf8))
        exit(64)
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let previewHost = MainActor.assumeIsolated { PreviewHost() }
    serve(path: arguments[flag + 1], host: previewHost)
    application.run()
    """#
}
