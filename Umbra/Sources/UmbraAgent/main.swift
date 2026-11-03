import Foundation
import UmbraAgentSupport

/// `umbra-agent run "prompt"` — the headless agent for scripts, git hooks and CI
/// (docs/harness/agent-harness-6.md Phase 2). Same permission files, same sandbox option,
/// same session store as the app; every approval, question and plan decision is refused
/// (there is no TTY), unless an allow rule or `--mode auto` covers the call.
///
/// Configuration order per value: flag, `UMBRA_AGENT_*` environment, Umbra's UserDefaults;
/// the key from the environment or Umbra's Keychain — never from a command-line argument.
/// Exit codes: 0 finished, 1 error, 2 stopped by a budget, 3 an approval was refused.
@main
struct UmbraAgent {
    static func main() async {
        let parsed: UmbraAgentCommandLine
        do {
            parsed = try UmbraAgentCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(Int32(UmbraAgentExitCode.error.rawValue))
        }

        let defaults = UserDefaults(suiteName: "com.umbra.editor") ?? .standard
        let environment = ProcessInfo.processInfo.environment
        let providerName = parsed.provider
            ?? environment["UMBRA_AGENT_PROVIDER"]
            ?? environment["UMBRA_ACP_PROVIDER"]
            ?? storedProvider(defaults: defaults)
        guard let provider = providerName.flatMap(UmbraAgentProvider.init(name:)) else {
            FileHandle.standardError.write(Data(
                "Unknown provider “\(providerName ?? "")”. Use openai|chat|anthropic|meta|ollama|mlx|apple|apple-pcc.\n".utf8))
            exit(Int32(UmbraAgentExitCode.error.rawValue))
        }

        let model = parsed.model
            ?? environment["UMBRA_AGENT_MODEL"]
            ?? environment["UMBRA_ACP_MODEL"]
            ?? storedField("model", provider: provider, defaults: defaults)
            ?? ""
        let baseURL = parsed.baseURL
            ?? environment["UMBRA_AGENT_BASE_URL"]
            ?? environment["UMBRA_ACP_BASE_URL"]
            ?? storedField("baseURL", provider: provider, defaults: defaults)
        let cwd: URL
        if let raw = parsed.workingDirectory {
            cwd = URL(fileURLWithPath: raw)
        } else {
            cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let resume: UUID?
        if let raw = parsed.resume {
            guard let id = UUID(uuidString: raw) else {
                FileHandle.standardError.write(Data("“\(raw)” is not a session id.\n".utf8))
                exit(Int32(UmbraAgentExitCode.error.rawValue))
            }
            resume = id
        } else {
            resume = nil
        }

        let request = UmbraAgentRunRequest(
            prompt: parsed.prompt,
            provider: UmbraAgentProviderConfig(
                provider: provider, model: model, baseURL: baseURL,
                keyStore: IDEAgentKeychain()),
            mode: parsed.permissionMode(),
            maxIterations: parsed.maxIterations,
            maxRunTokens: parsed.maxRunTokens,
            maxRunSeconds: parsed.maxRunSeconds.map(TimeInterval.init),
            workingDirectory: cwd,
            output: parsed.outputFormat(),
            resumeSessionID: resume,
            allowMCP: parsed.allowMCP,
            sandbox: parsed.sandbox,
            extraEnvironment: parsed.extraEnvironment,
            keyStore: IDEAgentKeychain())

        let result = await UmbraAgentHeadlessRun.run(request)
        switch parsed.outputFormat() {
        case .text:
            if !result.text.isEmpty { print(result.text) }
            if result.exitCode == .approvalRefused, let first = result.refusals.first {
                FileHandle.standardError.write(Data(
                    "Refused: \(first.title)\(first.command.map { " (\($0))" } ?? ""). Rerun with --mode auto or add an allow rule.\n".utf8))
            }
        case .json:
            print(result.jsonString())
        case .streamJson:
            // Per-event lines already went to stdout; close with the result object.
            print(result.jsonString(pretty: false))
        }
        exit(result.exitCode.rawValue)
    }

    // MARK: - Umbra settings fallback

    static func storedProvider(defaults: UserDefaults) -> String? {
        defaults.string(forKey: "umbra.agent.provider")
    }

    /// Per-provider fields, mirroring `IDEAgentSettings`: bare keys for Responses, suffixed otherwise.
    static func storedField(_ name: String, provider: UmbraAgentProvider, defaults: UserDefaults) -> String? {
        let raw: String
        switch provider {
        case .openAIResponses: raw = "responses"
        case .chatCompletions: raw = "chat"
        case .anthropic: raw = "anthropic"
        case .meta: raw = "meta"
        case .ollama: raw = "ollama"
        case .mlx: raw = "mlx"
        case .apple: raw = "apple"
        case .applePCC: raw = "apple-pcc"
        }
        if raw == "responses" { return defaults.string(forKey: "umbra.agent.\(name)") }
        return defaults.string(forKey: "umbra.agent.\(name).\(raw)")
    }
}
