@preconcurrency import AppKit
import Foundation

/// One tick on the error stripe: where in the document it sits (0 at the top, 1 at the bottom)
/// and how severe it is.
struct ErrorStripeMark: Equatable {
    var fraction: CGFloat
    var severity: TextViewDiagnosticSeverity
}

/// A slim strip along the trailing edge of a ``TextView`` with a tick for every diagnostic,
/// positioned by where it sits in the whole document, as in IntelliJ's error stripe. It never
/// takes mouse events, so the minimap and the scrollers underneath it keep working.
final class ErrorStripeView: EditorView {
    /// Width of the strip in points.
    static let width: CGFloat = 6

    /// Shortest tick, in points; set from ``TextView/errorStripeMinimumMarkHeight``.
    var minimumMarkHeight: CGFloat = 2 {
        didSet { if minimumMarkHeight != oldValue { needsDisplay = true } }
    }

    private(set) var marks: [ErrorStripeMark] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMarks(_ marks: [ErrorStripeMark]) {
        guard marks != self.marks else {
            return
        }
        self.marks = marks
        needsDisplay = true
    }

    /// Ticks as rectangles in this view's coordinates, least severe first so an error is painted
    /// over a warning that falls on the same spot.
    static func tickRects(
        for marks: [ErrorStripeMark], trackHeight: CGFloat, minimumMarkHeight: CGFloat
    ) -> [(rect: CGRect, severity: TextViewDiagnosticSeverity)] {
        guard trackHeight > 0 else {
            return []
        }
        let ordered = marks.sorted { $0.severity.stripeRank < $1.severity.stripeRank }
        return ordered.map { mark in
            let center = min(max(mark.fraction, 0), 1) * trackHeight
            let height = min(minimumMarkHeight, trackHeight)
            let y = min(max(center - height / 2, 0), trackHeight - height)
            return (CGRect(x: 0, y: y, width: width, height: height), mark.severity)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for tick in Self.tickRects(for: marks, trackHeight: bounds.height, minimumMarkHeight: minimumMarkHeight) {
            tick.severity.squiggleColor.withAlphaComponent(0.9).setFill()
            tick.rect.fill()
        }
    }
}

extension TextViewDiagnosticSeverity {
    /// Paint order on the stripe: higher is painted later, so on top.
    var stripeRank: Int {
        switch self {
        case .hint: return 0
        case .information: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
