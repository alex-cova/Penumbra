import Foundation
import GhosttyVt

/// One mouse interaction as the view reports it.
///
/// Coordinates are surface-space pixels (the view's coordinate space);
/// the encoder maps them to cells using the geometry from
/// `syncToTerminal(size:)`.
struct GhosttyMouseReport: Sendable {
    enum Action: Sendable {
        case press
        case release
        case motion
    }

    enum Button: Sendable {
        case left
        case right
        case middle
        /// Wheel up / scroll up.
        case wheelUp
        /// Wheel down / scroll down.
        case wheelDown
    }

    var action: Action
    /// Nil for motion without buttons.
    var button: Button?
    var modifiers: GhosttyModifiers = []
    var x: Float
    var y: Float
}

/// Encodes mouse interactions into VT sequences (X10/UTF-8/SGR/URxVT per
/// the terminal's live mouse protocol state).
///
/// Queue affinity: like `GhosttyKeystrokeEncoder`, touch only on the
/// terminal queue, syncing first with `syncToTerminal`.
final class GhosttyMouseReportEncoder {
    private var encoder: GhosttyMouseEncoder?

    init?() {
        var enc: GhosttyMouseEncoder?
        guard ghostty_mouse_encoder_new(nil, &enc) == GHOSTTY_SUCCESS, let enc else { return nil }
        encoder = enc
    }

    deinit {
        if let encoder { ghostty_mouse_encoder_free(encoder) }
    }

    /// Refreshes tracking mode/format from the terminal and sets the
    /// renderer geometry used for pixel→cell mapping. `anyButtonPressed`
    /// feeds drag-motion encoding.
    func syncToTerminal(
        _ terminal: GhosttyTerminal?,
        screenWidth: UInt32,
        screenHeight: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32,
        anyButtonPressed: Bool
    ) {
        guard let encoder, let terminal else { return }
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = screenWidth
        size.screen_height = screenHeight
        size.cell_width = max(cellWidth, 1)
        size.cell_height = max(cellHeight, 1)
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
    }

    /// Encodes one report. Returns nil when the event produces no output
    /// (tracking disabled, motion without buttons in normal mode, …).
    func encode(_ report: GhosttyMouseReport) -> Data? {
        guard let encoder else { return nil }
        var event: GhosttyMouseEvent?
        guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else { return nil }
        defer { ghostty_mouse_event_free(event) }

        switch report.action {
        case .press: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS)
        case .release: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_RELEASE)
        case .motion: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_MOTION)
        }
        switch report.button {
        case .left: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT)
        case .right: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_RIGHT)
        case .middle: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_MIDDLE)
        // xterm wheel buttons: up = 4, down = 5.
        case .wheelUp: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FOUR)
        case .wheelDown: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FIVE)
        case nil: ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, report.modifiers.rawValue)
        var position = GhosttyMousePosition(x: report.x, y: report.y)
        ghostty_mouse_event_set_position(event, position)

        var stack = [CChar](repeating: 0, count: 128)
        var written = 0
        let result: GhosttyResult = stack.withUnsafeMutableBufferPointer { ptr in
            ghostty_mouse_encoder_encode(encoder, event, ptr.baseAddress, ptr.count, &written)
        }
        if result == GHOSTTY_OUT_OF_SPACE {
            var heap = [CChar](repeating: 0, count: written)
            let retry: GhosttyResult = heap.withUnsafeMutableBufferPointer { ptr in
                ghostty_mouse_encoder_encode(encoder, event, ptr.baseAddress, ptr.count, &written)
            }
            guard retry == GHOSTTY_SUCCESS else { return nil }
            return Data(heap.prefix(written).map { UInt8(bitPattern: $0) })
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return Data(stack.prefix(written).map { UInt8(bitPattern: $0) })
    }
}
