@preconcurrency import AppKit
import CoreGraphics
import Foundation

func UIGraphicsGetCurrentContext() -> CGContext? {
    NSGraphicsContext.current?.cgContext
}

public final class UIBezierPath {
    private let path: CGMutablePath
    public init(roundedRect rect: CGRect, byRoundingCorners corners: UIRectCorner, cornerRadii: CGSize) {
        path = CGMutablePath()
        let radius = min(cornerRadii.width, cornerRadii.height)
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
    public var cgPath: CGPath { path }
}
