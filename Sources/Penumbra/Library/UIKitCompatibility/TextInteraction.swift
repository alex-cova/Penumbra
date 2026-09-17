@preconcurrency import AppKit
import Foundation

public enum UITextInteractionMode { case editable, nonEditable }

public protocol UITextInteractionDelegate: AnyObject {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool
    func interactionWillBegin(_ interaction: UITextInteraction)
    func interactionDidEnd(_ interaction: UITextInteraction)
}

extension UITextInteractionDelegate {
    public func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool { true }
    public func interactionWillBegin(_ interaction: UITextInteraction) {}
    public func interactionDidEnd(_ interaction: UITextInteraction) {}
}

public final class UITextInteraction: NSObject {
    public weak var textInput: (UIResponder & UITextInput)?
    public weak var delegate: UITextInteractionDelegate?
    public weak var view: UIView?
    public var textInteractionMode: UITextInteractionMode = .editable
    public var gesturesForFailureRequirements: [UIGestureRecognizer] = []
    public init(for mode: UITextInteractionMode) { textInteractionMode = mode; super.init() }
    public func require(toFail gestureRecognizer: UIGestureRecognizer) {}
}

public final class UITextSelectionDisplayInteraction: NSObject {
    public var isActivated = false
    public func sbs_enableCursorBlinks() {}
}

public protocol UIEditMenuInteractionDelegate: AnyObject {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu?
}

public final class UIEditMenuInteraction: NSObject {
    public weak var delegate: UIEditMenuInteractionDelegate?
    public init(delegate: UIEditMenuInteractionDelegate?) { self.delegate = delegate; super.init() }
    public func presentEditMenu(with configuration: UIEditMenuConfiguration) {}
}

public final class UIEditMenuConfiguration: NSObject {
    public let identifier: Any?
    public let sourcePoint: CGPoint
    public var preferredArrowDirection: UIEditMenuArrowDirection = .automatic
    public init(identifier: Any?, sourcePoint: CGPoint) { self.identifier = identifier; self.sourcePoint = sourcePoint; super.init() }
}

public enum UIEditMenuArrowDirection { case automatic, up, down }
public protocol UIMenuElement {}
public final class UIAction: NSObject, UIMenuElement {
    public let title: String
    public let handler: (UIAction) -> Void
    public init(title: String, handler: @escaping (UIAction) -> Void) { self.title = title; self.handler = handler; super.init() }
}
public final class UIMenu: NSObject {
    public let children: [UIMenuElement]
    public init(children: [UIMenuElement]) { self.children = children; super.init() }
}
public final class UIMenuItem: NSObject {
    public let title: String
    public let action: Selector
    public init(title: String, action: Selector) { self.title = title; self.action = action; super.init() }
}
public final class UIMenuController: NSObject, @unchecked Sendable {
    public static let shared = UIMenuController()
    public var menuItems: [UIMenuItem] = []
    public func showMenu(from view: UIView, rect: CGRect) {}
    public func hideMenu(from view: UIView) {}
}

@MainActor
public protocol UIFindInteractionDelegate: AnyObject {
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession?
}
public final class UIFindInteraction: NSObject {
    public weak var delegate: UIFindInteractionDelegate?
    public init(sessionDelegate: UIFindInteractionDelegate) { delegate = sessionDelegate; super.init() }
}
public protocol UIFindSession {}
public final class UITextSearchingFindSession: NSObject, UIFindSession {
    public init(searchableObject: AnyObject) { super.init() }
}

@MainActor
public protocol UITextSearching: AnyObject {
    var supportsTextReplacement: Bool { get }
    var selectedTextRange: UITextRange? { get }
    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult
    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<AnyHashable?>)
    func decorate(foundTextRange: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle)
    func clearAllDecoratedFoundText()
    func replaceAll(queryString: String, options: UITextSearchOptions, withText replacementText: String)
    func replace(foundTextRange: UITextRange, document: AnyHashable??, withText replacementText: String)
    func shouldReplace(foundTextRange: UITextRange, document: AnyHashable??, withText replacementText: String) -> Bool
    func scrollRangeToVisible(_ range: UITextRange, inDocument: AnyHashable??)
}

public final class UITextSearchAggregator<Document>: @unchecked Sendable {
    public func foundRange(_ range: UITextRange, searchString: String, document: Document) {}
    public func finishedSearching() {}
}
