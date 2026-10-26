import CoreGraphics
import Foundation

/// A phone the preview can be sized as. The preview host draws macOS SwiftUI, not iOS, so a device
/// gives the window its size in points and the panel its bezel; nothing here changes how controls
/// or safe areas render. Sizes are the displays' logical points; corner radii and bezels are
/// approximate (they only shape the drawing); the safe areas are the values iOS reports in portrait,
/// and the iPhone Air's is assumed to match the 17's.
struct IDESwiftUIPreviewDevice: Hashable, Sendable, Identifiable {
    enum Cutout: Hashable, Sendable {
        /// A home button below the screen and a large bezel (the SE).
        case homeButton
        case notch
        case dynamicIsland
    }

    var id: String
    var name: String
    /// Portrait size of the screen in points.
    var width: Int
    var height: Int
    /// The screen's corner radius.
    var cornerRadius: Double
    var cutout: Cutout
    /// The safe area at the top (the status bar and the island or notch) and at the bottom (the home
    /// indicator) in portrait, in points. The preview's content is laid out inside it, so nothing
    /// sits under the island.
    var safeTop: Double
    var safeBottom: Double

    var size: CGSize { CGSize(width: width, height: height) }

    /// The body around the screen: left and right, top, bottom.
    var bezelSide: Double { cutout == .homeButton ? 26 : 12 }
    var bezelTop: Double { cutout == .homeButton ? 96 : 12 }
    var bezelBottom: Double { cutout == .homeButton ? 104 : 12 }

    /// The body's own corner radius, concentric with the screen's.
    var bodyCornerRadius: Double { cornerRadius > 0 ? cornerRadius + bezelSide : 44 }

    static let all: [IDESwiftUIPreviewDevice] = [
        IDESwiftUIPreviewDevice(id: "iphone-17-pro-max", name: "iPhone 17 Pro Max", width: 440, height: 956, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-17-pro", name: "iPhone 17 Pro", width: 402, height: 874, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-air", name: "iPhone Air", width: 420, height: 912, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-17", name: "iPhone 17", width: 402, height: 874, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-16-pro-max", name: "iPhone 16 Pro Max", width: 440, height: 956, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-16-pro", name: "iPhone 16 Pro", width: 402, height: 874, cornerRadius: 62, cutout: .dynamicIsland, safeTop: 62, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-16-plus", name: "iPhone 16 Plus", width: 430, height: 932, cornerRadius: 55, cutout: .dynamicIsland, safeTop: 59, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-16", name: "iPhone 16", width: 393, height: 852, cornerRadius: 55, cutout: .dynamicIsland, safeTop: 59, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-16e", name: "iPhone 16e", width: 390, height: 844, cornerRadius: 47, cutout: .notch, safeTop: 47, safeBottom: 34),
        IDESwiftUIPreviewDevice(id: "iphone-se", name: "iPhone SE (3rd generation)", width: 375, height: 667, cornerRadius: 0, cutout: .homeButton, safeTop: 20, safeBottom: 0)
    ]
}

/// How much the preview is magnified on the canvas.
enum IDESwiftUIPreviewZoom: Hashable, Sendable, Identifiable {
    /// The whole frame in the panel (never above 100%).
    case fit
    /// 1 is 100%.
    case scale(Double)

    static let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    static let range: ClosedRange<Double> = 0.25...4

    var id: String {
        switch self {
        case .fit: return "fit"
        case .scale(let value): return "\(Int((value * 100).rounded()))"
        }
    }

    /// `nil` for `.fit`: it depends on the panel.
    var factor: Double? {
        if case .scale(let value) = self { return value }
        return nil
    }

    static func percentTitle(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// The next larger step above `value`, or the largest.
    static func next(after value: Double) -> Double {
        steps.first { $0 > value + 0.001 } ?? steps[steps.count - 1]
    }

    /// The next smaller step below `value`, or the smallest.
    static func previous(before value: Double) -> Double {
        steps.last { $0 < value - 0.001 } ?? steps[0]
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The arithmetic of the canvas, apart from the views.
enum IDESwiftUIPreviewLayout {
    /// Space kept around a frame that is scaled to fit.
    static let margin: Double = 16

    /// The window size to ask the host for when the canvas decides it: the panel divided by the
    /// zoom, so zooming out shows more of a layout that fills its window. At most 4096 a side.
    static func canvasWindowSize(viewport: CGSize, zoom: IDESwiftUIPreviewZoom) -> CGSize {
        guard let factor = zoom.factor, factor > 0 else { return viewport }
        return CGSize(
            width: min((viewport.width / factor).rounded(), 4096),
            height: min((viewport.height / factor).rounded(), 4096)
        )
    }

    /// How many panel points one point of the frame takes. `extra` is what is drawn around the
    /// frame in frame points (a device's bezel), which the fit leaves room for.
    static func displayScale(
        zoom: IDESwiftUIPreviewZoom, fillsCanvas: Bool, frameSize: CGSize, extra: CGSize, panel: CGSize
    ) -> Double {
        if let factor = zoom.factor { return factor }
        // A frame that is the panel's own size is shown as it is.
        if fillsCanvas { return 1 }
        let width = Double(frameSize.width + extra.width), height = Double(frameSize.height + extra.height)
        guard width > 0, height > 0 else { return 1 }
        let fit = min((Double(panel.width) - 2 * margin) / width, (Double(panel.height) - 2 * margin) / height)
        return min(1, max(0.1, fit))
    }

    /// A point of the frame image on the canvas, as a point of the frame. The image is shown at
    /// `viewSize` and is `frameSize` points of the preview.
    static func framePoint(_ point: CGPoint, viewSize: CGSize, frameSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, frameSize.width > 0, frameSize.height > 0 else { return point }
        return CGPoint(x: point.x * frameSize.width / viewSize.width, y: point.y * frameSize.height / viewSize.height)
    }
}
