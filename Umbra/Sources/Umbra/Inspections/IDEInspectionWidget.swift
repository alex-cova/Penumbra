import SwiftUI

/// The small badge at the top right of a Java or Swift editor: how many errors, warnings and weaker
/// problems the file has, or a check mark. A click opens the Problems tab for the file.
struct IDEInspectionWidget: View {
    static let defaultsKey = "umbra.editor.showsInspectionWidget"

    @Environment(IDEWorkspace.self) private var workspace
    @AppStorage(IDEInspectionWidget.defaultsKey) private var isEnabled = true
    let paneID: UUID

    private var url: URL? {
        workspace.workbench.layout.findPane(id: paneID)?.selectedDocument?.url
    }

    var body: some View {
        if isEnabled, let url, ["java", "swift"].contains(url.pathExtension.lowercased()) {
            let isJava = url.pathExtension.lowercased() == "java"
            let counts = workspace.problems.counts(for: url)
            // No editor report yet, or a stale source in the landed one: the rows belong
            // to older text (or nothing has landed), so a check mark would lie.
            let pending = !workspace.problems.hasEditorReport(for: url)
                || !workspace.problems.staleSources(for: url).isEmpty
            // The live compiler never checked this file: zero rows mean "not analysed", not
            // "clean", so the check mark stays off until it runs.
            let compilerState = workspace.javaSupport.compilerState
            // Swift's native analyses always run; only Java has a live compiler that may be off.
            let compilerOff = isJava && compilerState != .ready
            Button {
                workspace.inspectionRuns.selection = .file
                workspace.showProblems()
            } label: {
                HStack(spacing: 6) {
                    if pending {
                        ProgressView()
                            .scaleEffect(0.6)
                            .accessibilityHidden(true)
                    }
                    if counts.errors + counts.warnings + counts.weaker == 0 {
                        if !pending {
                            if compilerOff {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                            }
                        }
                    } else {
                        if counts.errors > 0 { badge("xmark.octagon.fill", counts.errors, IDEAppearance.ColorToken.error) }
                        if counts.warnings > 0 { badge("exclamationmark.triangle.fill", counts.warnings, IDEAppearance.ColorToken.gitModified) }
                        if counts.weaker > 0 { badge("lightbulb.fill", counts.weaker, IDEAppearance.ColorToken.muted) }
                    }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(IDEAppearance.ColorToken.card.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 18)
            .help(helpText(pending: pending, compilerOff: compilerOff, state: compilerState))
            .accessibilityLabel(accessibilityText(
                pending: pending, compilerOff: compilerOff,
                errors: counts.errors, warnings: counts.warnings, weaker: counts.weaker
            ))
        }
    }

    private func accessibilityText(pending: Bool, compilerOff: Bool, errors: Int, warnings: Int, weaker: Int) -> String {
        var text = "\(errors) errors, \(warnings) warnings, \(weaker) weaker problems in this file"
        if pending { text += ", analyzing" }
        if errors + warnings + weaker == 0, !pending, compilerOff {
            text += ", live compiler checks unavailable"
        }
        return text
    }

    private func helpText(pending: Bool, compilerOff: Bool, state: JavaCompilerState) -> String {
        if pending { return "Analyzing this file. Click to open its problems; F2 goes to the next one." }
        if compilerOff {
            switch state {
            case .disabled:
                return "Compiler diagnostics are off in Settings. Turn them on for live errors; build output still lists problems."
            case .waitingForModel:
                return "Waiting for the project's first sync. Live compiler errors start once it finishes; build output still lists problems."
            case .noJDK:
                return "No JDK with javac found. Choose one to get live compiler errors; build output still lists problems."
            case .ready:
                return "Problems in this file. Click to open them; F2 goes to the next one."
            }
        }
        return "Problems in this file. Click to open them; F2 goes to the next one."
    }

    private func badge(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(count)").font(IDEAppearance.Typography.monoSmall).foregroundStyle(IDEAppearance.ColorToken.foreground)
        }
    }
}
