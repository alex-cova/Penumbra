import AppKit
import Penumbra
import SwiftUI

/// Picks the expression Quick Evaluate (⌥⌘F8) asks about: the selection, or the name at the caret
/// with the `a.b[i].` chain that leads to it. Only text the debugger's evaluator can read is ever
/// returned, so calls and operators around the caret are left out.
enum IDEEvaluateExpressionScanner {
    private static let keywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "return", "new", "try", "catch", "finally", "throw",
        "class", "interface", "enum", "import", "package", "int", "long", "short", "byte", "char", "boolean",
        "float", "double", "void", "static", "final", "public", "private", "protected", "var"
    ]
    private static let maximumLength = 200

    static func expression(in text: String, selection: NSRange) -> String? {
        let string = text as NSString
        guard selection.location != NSNotFound, selection.location + selection.length <= string.length else { return nil }
        if selection.length > 0 {
            let selected = string.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty, selected.count <= maximumLength, !selected.contains("\n") else { return nil }
            return selected
        }
        let caret = selection.location
        var end = caret
        while end < string.length, isIdentifierPart(string.character(at: end)) { end += 1 }
        var start = caret
        while start > 0, isIdentifierPart(string.character(at: start - 1)) { start -= 1 }
        guard start < end else { return nil }
        // The chain in front: `a.b[i].` — a name, an index, or another dot-joined piece.
        while start > 1, string.character(at: start - 1) == dot {
            var piece = start - 1
            if piece > 0, string.character(at: piece - 1) == closeBracket {
                guard let open = openingBracket(before: piece - 1, in: string) else { break }
                piece = open
            }
            var name = piece
            while name > 0, isIdentifierPart(string.character(at: name - 1)) { name -= 1 }
            guard name < piece else { break }
            start = name
        }
        guard end - start <= maximumLength else { return nil }
        let result = string.substring(with: NSRange(location: start, length: end - start))
        return keywords.contains(result) ? nil : result
    }

    private static let dot: unichar = 0x2E
    private static let closeBracket: unichar = 0x5D
    private static let openBracket: unichar = 0x5B

    /// The `[` matching the `]` at `close`, looking back a bounded distance.
    private static func openingBracket(before close: Int, in string: NSString) -> Int? {
        var depth = 0
        var index = close
        while index >= 0, close - index < maximumLength {
            let c = string.character(at: index)
            if c == closeBracket { depth += 1 }
            if c == openBracket {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }

    private static func isIdentifierPart(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
    }
}

/// One value of the debugger, with a disclosure arrow when it has fields or elements. Opening one
/// asks the adapter for that level, so a large object graph is never fetched up front.
struct IDEDebugValueRow: View {
    let session: JavaDebugSession
    let value: JavaDebugValue

    @State private var isExpanded = false
    @State private var loaded: [JavaDebugValue]?
    @State private var loadError: String?

    var body: some View {
        if value.hasChildren {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children = loaded ?? value.children {
                    ForEach(children) { IDEDebugValueRow(session: session, value: $0) }
                } else if let loadError {
                    Text(loadError).font(IDEAppearance.Typography.caption).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                label
            }
            .onChange(of: isExpanded) { _, expanded in
                guard expanded, loaded == nil, value.children == nil else { return }
                Task { await load() }
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let name = value.name {
                Text(name).font(IDEAppearance.Typography.body.weight(.medium))
            }
            if !value.type.isEmpty {
                Text(value.type)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: IDEAppearance.Spacing.xs)
            Text(value.value)
                .font(IDEAppearance.Typography.monoSmall)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .help(value.value)
    }

    private func load() async {
        switch await session.evaluate(value.expression, record: false) {
        case .value(let node): loaded = node.children ?? []
        case .failure(let message): loadError = message
        }
    }
}

/// The Quick Evaluate popover's content: the expression and its value, evaluated as it appears.
private struct IDEQuickEvaluateView: View {
    let session: JavaDebugSession
    let expression: String

    @State private var outcome: JavaDebugEvaluation.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(expression)
                .font(IDEAppearance.Typography.monoSmall.weight(.semibold))
                .lineLimit(2)
            switch outcome {
            case nil:
                ProgressView().controlSize(.small)
            case .value(let value)?:
                ScrollView {
                    IDEDebugValueRow(session: session, value: value)
                }
                .frame(maxHeight: 260)
            case .failure(let message)?:
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
        .frame(minWidth: 260, maxWidth: 460, alignment: .leading)
        .task { outcome = await session.evaluate(expression, record: false) }
    }
}

/// Quick Evaluate: the value of the expression at the caret, in a popover next to it.
@MainActor
final class IDEQuickEvaluatePopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    func present(expression: String, session: JavaDebugSession, in textView: TextView, at location: Int) {
        dismiss()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: IDEQuickEvaluateView(session: session, expression: expression).preferredColorScheme(.dark)
        )
        self.popover = popover
        let caret = textView.caretRectInViewport(at: location)
        let anchor = caret.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 16) : caret.insetBy(dx: 0, dy: -1)
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
    }

    func dismiss() {
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
