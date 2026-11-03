import AgentKit
import Foundation

/// Parsed `umbra-agent run` arguments. Parsing lives in the library (not the executable)
/// so `UmbraTests` covers it without launching a process.
public struct UmbraAgentCommandLine: Sendable, Equatable {
    public var prompt: String
    public var provider: String?
    public var model: String?
    public var baseURL: String?
    public var mode: String
    public var maxIterations: Int?
    public var maxRunTokens: Int?
    public var maxRunSeconds: Int?
    public var workingDirectory: String?
    public var output: String
    public var resume: String?
    public var allowMCP: Bool
    public var sandbox: Bool
    public var extraEnvironment: [String: String]

    public init(
        prompt: String = "", provider: String? = nil, model: String? = nil,
        baseURL: String? = nil, mode: String = "accept-edits",
        maxIterations: Int? = nil, maxRunTokens: Int? = nil, maxRunSeconds: Int? = nil,
        workingDirectory: String? = nil, output: String = "text",
        resume: String? = nil, allowMCP: Bool = false, sandbox: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.mode = mode
        self.maxIterations = maxIterations
        self.maxRunTokens = maxRunTokens
        self.maxRunSeconds = maxRunSeconds
        self.workingDirectory = workingDirectory
        self.output = output
        self.resume = resume
        self.allowMCP = allowMCP
        self.sandbox = sandbox
        self.extraEnvironment = extraEnvironment
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable, Sendable {
        case message(String)
        public var description: String {
            if case .message(let text) = self { return text }
            return ""
        }
    }

    /// Parses `["run", "<prompt>", "--provider", ...]`. Anything before the first flag that is
    /// not `run` is the start of the prompt; `--` ends flag parsing.
    public static func parse(_ arguments: [String]) throws -> UmbraAgentCommandLine {
        var args = arguments
        guard !args.isEmpty else { throw ParseError.message(Self.usage) }
        if args.first == "run" { args.removeFirst() }
        var result = UmbraAgentCommandLine()
        var promptParts: [String] = []
        var flagsDone = false
        var index = 0
        func nextValue(flag: String) throws -> String {
            guard index + 1 < args.count else { throw ParseError.message("Missing value for \(flag).") }
            index += 1
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            if flagsDone || !arg.hasPrefix("--") {
                promptParts.append(arg)
            } else if arg == "--" {
                flagsDone = true
            } else if arg == "--provider" {
                result.provider = try nextValue(flag: arg)
            } else if arg == "--model" {
                result.model = try nextValue(flag: arg)
            } else if arg == "--base-url" {
                result.baseURL = try nextValue(flag: arg)
            } else if arg == "--mode" {
                result.mode = try nextValue(flag: arg)
            } else if arg == "--max-iterations" {
                guard let value = Int(try nextValue(flag: arg)), value > 0 else {
                    throw ParseError.message("--max-iterations needs a positive integer.")
                }
                result.maxIterations = value
            } else if arg == "--max-run-tokens" {
                guard let value = Int(try nextValue(flag: arg)), value > 0 else {
                    throw ParseError.message("--max-run-tokens needs a positive integer.")
                }
                result.maxRunTokens = value
            } else if arg == "--max-run-seconds" {
                guard let value = Int(try nextValue(flag: arg)), value > 0 else {
                    throw ParseError.message("--max-run-seconds needs a positive integer.")
                }
                result.maxRunSeconds = value
            } else if arg == "--cwd" {
                result.workingDirectory = try nextValue(flag: arg)
            } else if arg == "--output" {
                result.output = try nextValue(flag: arg)
            } else if arg == "--resume" {
                result.resume = try nextValue(flag: arg)
            } else if arg == "--allow-mcp" {
                result.allowMCP = true
            } else if arg == "--sandbox" {
                result.sandbox = true
            } else if arg == "--env" {
                let pair = try nextValue(flag: arg)
                guard let equals = pair.firstIndex(of: "="), !pair[..<equals].isEmpty else {
                    throw ParseError.message("--env needs KEY=VALUE.")
                }
                result.extraEnvironment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            } else if arg == "--help" || arg == "-h" {
                throw ParseError.message(Self.usage)
            } else {
                throw ParseError.message("Unknown flag \(arg).\n\(Self.usage)")
            }
            index += 1
        }
        result.prompt = promptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.prompt.isEmpty else { throw ParseError.message("Give a prompt.\n\(Self.usage)") }
        guard ["plan", "accept-edits", "auto", "manual"].contains(result.mode) else {
            throw ParseError.message("Unknown --mode \(result.mode). Use plan|accept-edits|auto|manual.")
        }
        guard ["text", "json", "stream-json"].contains(result.output) else {
            throw ParseError.message("Unknown --output \(result.output). Use text|json|stream-json.")
        }
        return result
    }

    public static let usage = """
        Usage: umbra-agent run "prompt" [options]
          --provider openai|chat|anthropic|meta|ollama|mlx|apple|apple-pcc
          --model <name>            Model id (not needed for apple/apple-pcc)
          --base-url <url>          Endpoint override for HTTP providers
          --mode plan|accept-edits|auto|manual   (default accept-edits)
          --max-iterations <n>      Model turns before the run pauses
          --max-run-tokens <n>      Input+output token budget for the run
          --max-run-seconds <n>     Wall-clock budget for the run
          --cwd <dir>               Project directory (default: current directory)
          --output text|json|stream-json   (default text)
          --resume <session>        Continue a saved session id
          --allow-mcp               Start the project's MCP servers (.umbra/mcp.json, .mcp.json)
          --sandbox                 Run commands under the workspace Seatbelt profile
          --env KEY=VALUE           Extra command environment (repeatable)
        Keys come from the environment (e.g. ANTHROPIC_API_KEY) or Umbra's Keychain.
        """

    public func permissionMode() -> PermissionMode {
        switch mode {
        case "plan": .plan
        case "auto": .auto
        case "manual": .manual
        default: .acceptEdits
        }
    }

    public func outputFormat() -> UmbraAgentOutputFormat {
        switch output {
        case "json": .json
        case "stream-json": .streamJson
        default: .text
        }
    }
}
