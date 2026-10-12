import AppKit
import SwiftUI
import ToyKit
import PreviewSupport
import Darwin

struct Wrap<Content: View>: View {
    let token: Int
    let content: () -> Content
    var body: some View { content() }
}
var wrapToken = 0

@MainActor
final class Host {
    let hosting = NSHostingView(rootView: AnyView(Wrap(token: 0) { CounterView() }))
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 260, height: 200))
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["DARK"] != nil ? .darkAqua : .aqua)
        let mode = ProcessInfo.processInfo.environment["WINMODE"] ?? "off"
        switch mode {
        case "on": window.setFrameOrigin(NSPoint(x: 200, y: 200))
        case "alpha": window.setFrameOrigin(NSPoint(x: 200, y: 200)); window.alphaValue = 0.01
        default: window.setFrameOrigin(NSPoint(x: -3000, y: 0))
        }
        window.orderFrontRegardless()
    }

    func snapshot(to path: String) {
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        say("frame \(path) \(Int(bounds.width))x\(Int(bounds.height))")
    }

    func snapshotLayer(to path: String) {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let scale = window.backingScaleFactor
        let size = hosting.bounds.size
        guard let layer = hosting.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { say("no layer"); return }
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        say("layerframe \(path) \(image.width)x\(image.height)")
    }

    func say(_ s: String) { print(s); fflush(stdout) }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        switch command {
        case "load":
            guard dlopen(parts[1], RTLD_NOW) != nil else { say("ERR \(String(cString: dlerror()))"); return }
            say("loaded")
            // Re-create the root so bodies are re-evaluated through the replaced implementation.
            hosting.rootView = AnyView(CounterView().id(UUID()))
        case "reload2":
            guard dlopen(parts[1], RTLD_NOW) != nil else { say("ERR \(String(cString: dlerror()))"); return }
            UmbraReload.shared.bump()
            say("bumped")
        case "snap": snapshot(to: parts[1])
        case "lsnap": snapshotLayer(to: parts[1])
        case "isnap":
            let r = ImageRenderer(content: CounterView())
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                say("imagerenderer \(parts[1])")
            }
        case "click":
            let p = hosting.convert(NSPoint(x: Double(parts.count > 1 ? Double(parts[1].split(separator: ",")[0])! : 150), y: Double(parts.count > 1 ? Double(parts[1].split(separator: ",")[1])! : 110)), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(ev)
                }
            }
            say("clicked")
        case "quit": exit(0)
        default: say("?")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = MainActor.assumeIsolated { Host() }
let source = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
var buffer = Data()
source.setEventHandler {
    var chunk = [UInt8](repeating: 0, count: 4096)
    let n = read(0, &chunk, chunk.count)
    if n <= 0 { exit(0) }
    buffer.append(contentsOf: chunk[0..<n])
    while let nl = buffer.firstIndex(of: 10) {
        let line = String(decoding: buffer[..<nl], as: UTF8.self)
        buffer.removeSubrange(...nl)
        MainActor.assumeIsolated { host.handle(line) }
    }
}
source.resume()
app.run()
