import Foundation

enum IDEUIColorTint {
    static func composite(_ tint: UInt32, over surface: UInt32) -> UInt32 {
        let alpha = Double(tint & 0xFF) / 255
        guard alpha < 1 else { return tint >> 8 & 0xFFFFFF }
        let tintRGB = tint >> 8
        let inverse = 1 - alpha
        func blend(_ channel: UInt32, _ base: UInt32) -> UInt32 {
            UInt32(Double(channel) * alpha + Double(base) * inverse)
        }
        let red = blend((tintRGB >> 16) & 0xFF, (surface >> 16) & 0xFF)
        let green = blend((tintRGB >> 8) & 0xFF, (surface >> 8) & 0xFF)
        let blue = blend(tintRGB & 0xFF, surface & 0xFF)
        return (red << 16) | (green << 8) | blue
    }

    static func composite(rgb: UInt32, alpha: Double, over surface: UInt32) -> UInt32 {
        let inverse = 1 - alpha
        func blend(_ channel: UInt32, _ base: UInt32) -> UInt32 {
            UInt32(Double(channel) * alpha + Double(base) * inverse)
        }
        let red = blend((rgb >> 16) & 0xFF, (surface >> 16) & 0xFF)
        let green = blend((rgb >> 8) & 0xFF, (surface >> 8) & 0xFF)
        let blue = blend(rgb & 0xFF, surface & 0xFF)
        return (red << 16) | (green << 8) | blue
    }
}
