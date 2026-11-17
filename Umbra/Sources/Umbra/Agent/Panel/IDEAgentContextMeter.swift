import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// How full the model's window is: a ring and a percentage, turning orange and then red as it fills.
/// The menu summarizes the earlier conversation to make room.
struct IDEAgentContextMeter: View {
    let fraction: Double
    let tokens: Int
    let window: Int
    let isBusy: Bool
    let compact: () -> Void

    private var tint: Color {
        switch fraction {
        case ..<0.75: IDEAppearance.ColorToken.muted
        case ..<0.9: .orange
        default: IDEAppearance.ColorToken.error
        }
    }

    var body: some View {
        Menu {
            Text("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in use")
            Button("Summarize the Earlier Conversation", action: compact)
                .disabled(isBusy)
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(IDEAppearance.ColorToken.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(tint)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in the model's window. Older messages are summarized automatically as it fills; /compact does it now.")
        .accessibilityLabel("Context window \(Int((fraction * 100).rounded())) percent full")
    }
}
