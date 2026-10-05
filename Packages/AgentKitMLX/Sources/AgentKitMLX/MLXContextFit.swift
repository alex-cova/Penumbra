import AgentKit
import Foundation

/// Whether a prompt's estimated size is past the window the session (or the model) was given.
/// `MLXLLMClient` throws `LLMError.contextLengthExceeded` when it is, so the session's forced
/// compaction pass runs. The estimate is the same byte count the session compacts with.
public enum MLXContextFit {
    public static func exceeds(_ request: LLMRequest, window: Int) -> Bool {
        guard window > 0 else { return false }
        let prompt = ContextBudget.tokens(system: request.system, tools: request.tools) + ContextBudget.tokens(request.items)
        return prompt > window
    }
}
