@preconcurrency import AppKit

/// Core Animation recipes for the caret. The animations run in the render server, so the blink
/// keeps going while the main thread is busy or the run loop is tracking an event.
enum CaretAnimation {
    static let blinkKey = "penumbra.caret.blink"
    static let moveKey = "penumbra.caret.move"
    /// How long the caret takes to glide to a new position.
    static let moveDuration: CFTimeInterval = 0.07
    static let minimumBlinkInterval: TimeInterval = 0.1
    static let maximumBlinkInterval: TimeInterval = 2.0

    static func clampedBlinkInterval(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, minimumBlinkInterval), maximumBlinkInterval)
    }

    /// One cycle is a visible phase followed by a hidden phase, each `interval` long. A hard blink
    /// flips opacity; a smooth one holds, fades out over part of the phase, holds, and fades back in.
    static func blink(interval: TimeInterval, smooth: Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.duration = clampedBlinkInterval(interval) * 2
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        if smooth {
            animation.values = [1, 1, 0, 0, 1]
            animation.keyTimes = [0, 0.3, 0.5, 0.8, 1]
            animation.calculationMode = .linear
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
        } else {
            animation.values = [1, 0]
            animation.keyTimes = [0, 0.5]
            animation.calculationMode = .discrete
        }
        return animation
    }
}
