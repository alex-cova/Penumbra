import SwiftUI

/// Tools ▸ Encode / Decode ▸ Decode JWT…: a token's header, payload and times, read-only. The
/// signature is shown but never checked.
struct IDEJWTSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let decoding: IDEJWTDecoding

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text("JWT")
                    .font(IDEAppearance.Typography.brandTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if let algorithm = decoding.algorithm {
                    Text(algorithm)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
                }
                Spacer()
            }
            statusRow

            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    section("Header", text: decoding.header)
                    section("Payload", text: decoding.payload)
                    if !decoding.timeClaims.isEmpty { timeClaims }
                    section("Signature", text: decoding.signature.isEmpty ? "(none)" : decoding.signature)
                }
            }
            .frame(maxHeight: 380)

            Text("The signature is shown, not verified.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(decoding.summary, forType: .string)
                }
                Button("Insert as Comment") { workspace.insertJWTAsComment(decoding) }
                    .disabled(decoding.anchorOffset == nil)
                Spacer()
                Button("Done") { workspace.jwtDecoding = nil }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 560)
    }

    private var statusRow: some View {
        let (text, color) = status
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
        }
    }

    private var status: (String, Color) {
        switch decoding.status {
        case .noExpiry:
            ("No expiry", IDEAppearance.ColorToken.muted)
        case .valid(let date):
            ("Expires \(Self.relative(date))", IDEAppearance.ColorToken.gitAdded)
        case .expired(let date):
            ("Expired \(Self.relative(date))", IDEAppearance.ColorToken.error)
        case .notYetValid(let date):
            ("Not valid until \(Self.relative(date))", IDEAppearance.ColorToken.gitModified)
        }
    }

    private var timeClaims: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Times")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ForEach(decoding.timeClaims, id: \.name) { claim in
                HStack(spacing: IDEAppearance.Spacing.md) {
                    Text(claim.name)
                        .frame(width: 32, alignment: .leading)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text(ISO8601DateFormatter().string(from: claim.date))
                        .textSelection(.enabled)
                    Text("(\(Self.relative(claim.date)))")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IDEAppearance.Spacing.sm)
                .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
        }
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
