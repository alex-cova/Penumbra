import AppKit
import SwiftUI

/// Laid over the preview's frame: turns the mouse, the scroll wheel and the keyboard into what the
/// session sends the host. Points are the frame's own (top-left origin, as the host's view has).
struct IDESwiftUIPreviewInput: NSViewRepresentable {
    let session: IDESwiftUIPreviewSession

    func makeNSView(context: Context) -> IDESwiftUIPreviewInputView {
        IDESwiftUIPreviewInputView(session: session)
    }

    func updateNSView(_ view: IDESwiftUIPreviewInputView, context: Context) {
        view.session = session
        session.swipeActionsHandler = { [weak view] point, names in view?.showSwipeActions(names, at: point) }
    }
}

final class IDESwiftUIPreviewInputView: NSView {
    weak var session: IDESwiftUIPreviewSession?

    init(session: IDESwiftUIPreviewSession) {
        self.session = session
        super.init(frame: .zero)
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(rect: bounds).fill()
    }

    // MARK: Mouse

    /// Where the event is in the preview's own points: the frame may be shown zoomed.
    private func point(of event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        guard let session else { return local }
        return IDESwiftUIPreviewLayout.framePoint(local, viewSize: bounds.size, frameSize: session.frameSize)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session?.mouse("down", at: point(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        session?.mouse("dragged", at: point(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        session?.mouse("up", at: point(of: event))
    }

    override func scrollWheel(with event: NSEvent) {
        // `scrollingDeltaY` is positive when the content is to move down (already in the user's
        // direction setting); the host's `dy` brings later content in, so the sign flips. A wheel
        // without precise deltas counts in lines.
        var unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // Shown zoomed, a point on the canvas is more or less than a point of the preview.
        if let session, bounds.width > 0, session.frameSize.width > 0 { unit *= session.frameSize.width / bounds.width }
        session?.scroll(
            at: point(of: event),
            dx: Double(-event.scrollingDeltaX * unit),
            dy: Double(-event.scrollingDeltaY * unit)
        )
    }

    // MARK: Keyboard

    /// Editing commands by key code; shift adds the "modify selection" form where there is one.
    private static let commands: [UInt16: (plain: String, shifted: String)] = [
        51: ("deleteBackward:", "deleteBackward:"),
        117: ("deleteForward:", "deleteForward:"),
        36: ("insertNewline:", "insertNewline:"),
        76: ("insertNewline:", "insertNewline:"),
        48: ("insertTab:", "insertBacktab:"),
        53: ("cancelOperation:", "cancelOperation:"),
        123: ("moveLeft:", "moveLeftAndModifySelection:"),
        124: ("moveRight:", "moveRightAndModifySelection:"),
        125: ("moveDown:", "moveDownAndModifySelection:"),
        126: ("moveUp:", "moveUpAndModifySelection:"),
        115: ("moveToBeginningOfLine:", "moveToBeginningOfLineAndModifySelection:"),
        119: ("moveToEndOfLine:", "moveToEndOfLineAndModifySelection:"),
        116: ("pageUp:", "pageUpAndModifySelection:"),
        121: ("pageDown:", "pageDownAndModifySelection:")
    ]

    /// What a key press asks of the focused view.
    enum KeyAction: Equatable {
        case command(String)
        case text(String)
        /// Not for the preview: a menu shortcut, or a key that types nothing.
        case ignored
    }

    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        // Menu shortcuts (⌘C, ⌘V…) come through `performKeyEquivalent` and the actions below.
        if flags.contains(.command) || flags.contains(.control) { return .ignored }
        if let pair = commands[keyCode] {
            return .command(flags.contains(.shift) ? pair.shifted : pair.plain)
        }
        guard let characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) })
        else { return .ignored }
        return .text(characters)
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        switch Self.keyAction(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.characters) {
        case .command(let selector): session.perform(command: selector)
        case .text(let text): session.type(text)
        case .ignored: super.keyDown(with: event)
        }
    }

    // MARK: Swipe actions

    /// What a swipe on a row of an iOS preview reveals, as a menu where the pointer is.
    private struct SwipeRequest {
        let name: String
        let point: CGPoint
    }

    func showSwipeActions(_ names: [String], at point: CGPoint) {
        guard let window else { return }
        let menu = NSMenu()
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(runSwipeAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SwipeRequest(name: name, point: point)
            menu.addItem(item)
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    @objc private func runSwipeAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SwipeRequest else { return }
        session?.perform(customAction: request.name, at: request.point)
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { session?.perform(action: "copy:") }
    @objc func cut(_ sender: Any?) { session?.perform(action: "cut:") }
    @objc func paste(_ sender: Any?) { session?.perform(action: "paste:") }
    @objc override func selectAll(_ sender: Any?) { session?.perform(action: "selectAll:") }
}
