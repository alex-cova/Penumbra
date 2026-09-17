@preconcurrency import AppKit
import Foundation

@MainActor
public protocol KeyboardObserverDelegate: AnyObject {
    func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillShowWithHeight keyboardHeight: CGFloat, animation: KeyboardObserver.Animation?)
    func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillHideWith animation: KeyboardObserver.Animation?)
    func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillChangeHeightTo keyboardHeight: CGFloat, animation: KeyboardObserver.Animation?)
}

extension KeyboardObserverDelegate {
    public func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillShowWithHeight keyboardHeight: CGFloat, animation: KeyboardObserver.Animation?) {}
    public func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillHideWith animation: KeyboardObserver.Animation?) {}
    public func keyboardObserver(_ keyboardObserver: KeyboardObserver, keyboardWillChangeHeightTo keyboardHeight: CGFloat, animation: KeyboardObserver.Animation?) {}
}

public final class KeyboardObserver {
    public struct Animation {
        public let duration: TimeInterval
        public let curve: UIView.AnimationOptions
        @MainActor
        public func run(animations: @escaping @Sendable () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
            UIView.animate(withDuration: duration, delay: 0, options: curve, animations: animations, completion: completion)
        }
    }
    public weak var delegate: KeyboardObserverDelegate?
    public private(set) var keyboardHeight: CGFloat = 0
    public private(set) var isKeyboardVisible = false
}

extension UIView {
    public struct AnimationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
    }
    public enum AnimationCurve: Int { case easeInOut = 0, easeIn = 1, easeOut = 2, linear = 3 }
    public static func animate(withDuration duration: TimeInterval, delay: TimeInterval, options: AnimationOptions, animations: @escaping @Sendable () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { $0.duration = duration; animations() } completionHandler: { completion?(true) }
    }
    public static func performWithoutAnimation(_ actions: () -> Void) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0; actions() }
    }
}
