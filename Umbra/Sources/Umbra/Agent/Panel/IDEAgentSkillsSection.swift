import AgentKit
import AppKit
import SwiftUI

/// Settings ▸ Agent ▸ Skills: every skill Umbra found, where from, with a switch for each, the ones a folder
/// read earlier hides, what could not be loaded and why, and whether a project's skill may pre-approve tools.
struct IDEAgentSkillsSection: View {
    let settings: IDEAgentSettings
    let agent: IDEAgentController?
    @State private var catalog: SkillCatalog?

    var body: some View {
        Section("Skills") {
            Text("A skill is a folder with a SKILL.md: instructions the agent loads when a task matches, or you start with /name. Umbra reads .umbra/skills, .claude/skills and .agents/skills in the project (and in the folders above it up to its repository), then ~/.claude/skills and ~/.agents/skills, then its own folder. The first one found with a name wins.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            if let catalog {
                if catalog.skills.isEmpty && catalog.shadowed.isEmpty {
                    ContentUnavailableView(
                        "No Skills",
                        systemImage: "sparkles",
                        description: Text("Add a folder with a SKILL.md to .agents/skills in your project or in your home folder."))
                }
                ForEach(catalog.skills, id: \.location) { skill in
                    row(skill)
                }
                let shadowed = catalog.shadowed
                if !shadowed.isEmpty {
                    Text("Hidden by a skill with the same name")
                        .font(IDEAppearance.Typography.caption.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(shadowed, id: \.location) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            Text(path(skill.location))
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(IDEAgentSkillsSection.shadowMessage(for: skill, in: catalog))
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                }
                let problems = Self.problems(in: catalog)
                if !problems.isEmpty {
                    Text("Problems reading skills")
                        .font(IDEAppearance.Typography.caption.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(diagnostic.message, systemImage: diagnostic.kind == .skipped ? "xmark.circle" : "exclamationmark.triangle")
                                .font(IDEAppearance.Typography.caption)
                            Text(abbreviated(diagnostic.path))
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Button("Rescan") { reload(forced: true) }
        }
        .onAppear { reload(forced: false) }
    }

    private func reload(forced: Bool) {
        if forced { agent?.commandCatalog.invalidate() }
        catalog = agent?.commandCatalog.allSkillsCatalog
    }

    private func row(_ skill: Skill) -> some View {
        let enabled = Binding(get: { settings.isSkillEnabled(skill.name) }, set: { settings.setSkill(skill.name, enabled: $0) })
        let state = IDEAgentSkillConsent.state(of: skill, trust: settings.skillTrust)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                    ForEach(Self.badges(for: skill), id: \.self) { badge in
                        Text(badge)
                            .font(IDEAppearance.Typography.caption)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(skill.description)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(2)
                Text("\(skill.source)  ·  \(path(skill.location))")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if state != .notNeeded {
                    trustLine(state, skill: skill)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([skill.location])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Toggle("", isOn: enabled)
                .labelsHidden()
                .help(enabled.wrappedValue ? "On: offered after / and to the agent" : "Off: not offered anywhere")
        }
        .opacity(enabled.wrappedValue ? 1 : 0.55)
    }

    @ViewBuilder
    private func trustLine(_ state: IDEAgentSkillConsent.State, skill: Skill) -> some View {
        let tools = skill.allowedTools.joined(separator: ", ")
        HStack(spacing: 6) {
            switch state {
            case .trusted:
                Text("You allowed it to pre-approve: \(tools)")
            case .declined:
                Text("You declined its pre-approved tools: \(tools)")
            default:
                Text("Wants to pre-approve \(tools); /\(skill.name) asks first.")
            }
            if state != .unknown {
                Button("Revoke") { settings.skillTrust.forget(IDEAgentSkillTrust.fingerprint(of: skill)) }
                    .buttonStyle(.link)
            }
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    // MARK: - Pure pieces

    static func badges(for skill: Skill) -> [String] {
        var badges: [String] = []
        if !skill.modelInvocable { badges.append("Only you") }
        if !skill.userInvocable { badges.append("Only the agent") }
        if !skill.paths.isEmpty { badges.append("Conditional") }
        return badges
    }

    /// Skipped files and warnings, except the shadowing ones, which have a group of their own.
    static func problems(in catalog: SkillCatalog) -> [SkillDiagnostic] {
        catalog.diagnostics.filter { !$0.message.hasPrefix("Shadowed") }
    }

    static func shadowMessage(for skill: Skill, in catalog: SkillCatalog) -> String {
        catalog.diagnostics.first { $0.path == skill.location.path && $0.message.hasPrefix("Shadowed") }?.message
            ?? "Another skill with this name is read first."
    }

    private func path(_ url: URL) -> String { abbreviated(url.path) }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
