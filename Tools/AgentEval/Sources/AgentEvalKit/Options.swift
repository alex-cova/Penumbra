import Foundation

public enum Command: String, Sendable {
    case run, list, validate, help
}

public struct UsageError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// `agent-eval <command> [options]`. Options are `--name value` or the flags `--keep` and `--no-run-tests`.
public struct Options: Sendable {
    public var command: Command = .help

    public init() {}
    public var provider = "ollama"
    public var model: String?
    public var baseURL: String?
    public var apiKeyEnvironment: String?
    public var trials = 1
    public var taskIDs: [String]?
    public var taskDirectory: URL?
    public var toolset: Toolset = .full
    public var offerRunTests = true
    public var maxIterations = 40
    public var contextWindow: Int?
    public var reasoning: String?
    public var trialTimeout: TimeInterval = 600
    public var jobs = 1
    public var jsonPath: String?
    public var transcriptsPath: String?
    public var keepSandboxes = false
    public var modelsDirectory: URL?

    public static let usage = """
    agent-eval: runs scripted coding tasks against a model and checks the result with the project's own tests.

    USAGE
      agent-eval run --provider <p> --model <name> [options]
      agent-eval list [--task-dir DIR]
      agent-eval validate [--tasks a,b] [--task-dir DIR]

    PROVIDERS  (--provider)
      ollama   a local Ollama server (default http://localhost:11434); needs --model
      openai   OpenAI Responses API; key from OPENAI_API_KEY
      chat     any OpenAI-compatible Chat Completions server (--base-url, optional key)
      mlx      an on-device MLX model installed through Umbra (--model is its repository id)

    OPTIONS
      --model NAME          model to test (required for run)
      --base-url URL        server base URL (openai default https://api.openai.com/v1)
      --api-key-env VAR     environment variable holding the API key (default OPENAI_API_KEY)
      --trials N            runs per task (default 1)
      --tasks a,b           only these tasks
      --task-dir DIR        tasks folder (default: Tools/AgentEval/Tasks of this checkout)
      --toolset full|core   core drops apply_patch, todo and the file walkers (default full)
      --no-run-tests        do not offer run_tests: the model must find bugs by reading
      --max-iterations N    model turns per task (default 40)
      --context N           context window in tokens: local models are asked for it, and the
                            session compacts as it fills (default: the model's own / no compaction)
      --reasoning LEVEL     reasoning effort for models that take one (low, medium, high)
      --timeout SECONDS     wall-clock limit per trial (default 600)
      --jobs N              trials in parallel; leave at 1 for local models (default 1)
      --json PATH           also write the full results as JSON
      --transcripts DIR     write one readable transcript per trial
      --keep                keep each trial's project folder
      --models-dir DIR      mlx only: the folder holding installed models (default: Umbra's, in
                            Application Support/com.umbra.editor/Models)
    """

    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        guard let first = rest.popFirst() else { return options }
        guard let command = Command(rawValue: first) else {
            if first == "-h" || first == "--help" { return options }
            throw UsageError("Unknown command “\(first)”.")
        }
        options.command = command
        while let flag = rest.popFirst() {
            func value() throws -> String {
                guard let next = rest.popFirst() else { throw UsageError("\(flag) needs a value.") }
                return next
            }
            func number() throws -> Int {
                let text = try value()
                guard let parsed = Int(text), parsed > 0 else { throw UsageError("\(flag) needs a positive number, not “\(text)”.") }
                return parsed
            }
            switch flag {
            case "--provider": options.provider = try value()
            case "--model": options.model = try value()
            case "--base-url": options.baseURL = try value()
            case "--api-key-env": options.apiKeyEnvironment = try value()
            case "--trials": options.trials = try number()
            case "--tasks": options.taskIDs = try value().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--task-dir": options.taskDirectory = URL(fileURLWithPath: try value())
            case "--toolset":
                let name = try value()
                guard let toolset = Toolset(rawValue: name) else { throw UsageError("--toolset is full or core, not “\(name)”.") }
                options.toolset = toolset
            case "--no-run-tests": options.offerRunTests = false
            case "--max-iterations": options.maxIterations = try number()
            case "--context": options.contextWindow = try number()
            case "--reasoning": options.reasoning = try value()
            case "--timeout": options.trialTimeout = TimeInterval(try number())
            case "--jobs": options.jobs = try number()
            case "--json": options.jsonPath = try value()
            case "--transcripts": options.transcriptsPath = try value()
            case "--keep": options.keepSandboxes = true
            case "--models-dir": options.modelsDirectory = URL(fileURLWithPath: try value())
            case "-h", "--help": options.command = .help
            default: throw UsageError("Unknown option “\(flag)”.")
            }
        }
        return options
    }
}
