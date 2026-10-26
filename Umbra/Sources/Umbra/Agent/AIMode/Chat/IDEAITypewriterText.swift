import SwiftUI

/// The Chat greeting, typed one character at a time and cycling through a set of prompts.
/// The task ends when the view leaves (a sent message removes the greeting), so the typing
/// stops with it. Shows the first message statically when animation is off.
struct IDEAITypewriterText: View {
    let messages: [String]
    let animated: Bool

    @State private var text: String

    init(messages: [String], animated: Bool) {
        self.messages = messages
        self.animated = animated
        _text = State(initialValue: messages.first ?? "")
    }

    var body: some View {
        Text(text)
            .font(IDEAppearance.Typography.brandTitle)
            .foregroundStyle(IDEAppearance.ColorToken.foreground)
            .multilineTextAlignment(.center)
            .task { await run() }
    }

    private func run() async {
        guard animated, !messages.isEmpty else { return }
        // The first message is already showing; hold it, then cycle from the second.
        try? await Task.sleep(for: .milliseconds(1600))
        var index = 1
        while !Task.isCancelled {
            let message = messages[index % messages.count]
            let current = text
            let shared = current.commonPrefix(with: message)
            for count in stride(from: current.count - 1, through: shared.count, by: -1) {
                if Task.isCancelled { return }
                text = String(current.prefix(count))
                try? await Task.sleep(for: .milliseconds(14))
            }
            if shared.count < message.count {
                for count in (shared.count + 1)...message.count {
                    if Task.isCancelled { return }
                    text = String(message.prefix(count))
                    try? await Task.sleep(for: .milliseconds(45))
                }
            }
            // When the messages share nothing, shared.count is 0 and the ranges above
            // delete the whole text and retype the message from its first character.
            try? await Task.sleep(for: .milliseconds(1600))
            index += 1
        }
    }
}
