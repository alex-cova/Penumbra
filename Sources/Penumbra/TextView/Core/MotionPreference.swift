import AppKit

/// The system Reduce Motion switch, read in one place so the caret, the scrollers, animated
/// scrolling and the distraction-free chrome fade all follow it.
enum MotionPreference {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
