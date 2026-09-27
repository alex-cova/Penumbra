@preconcurrency import AppKit
import CoreGraphics
import Foundation

public final class EditorBezierPath {
    private let path: CGMutablePath
    public init(roundedRect rect: CGRect, byRoundingCorners corners: RectCorner, cornerRadii: CGSize) {
        path = CGMutablePath()
        let radius = min(cornerRadii.width, cornerRadii.height)
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
    public var cgPath: CGPath { path }
}
