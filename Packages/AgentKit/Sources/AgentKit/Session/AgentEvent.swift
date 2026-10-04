import Foundation

public enum AgentState: Sendable, Equatable {
    case idle
    case streaming
    case runningTools([String])
    /// A command is waiting for the user's decision.
    case awaitingApproval(callID: String)
    /// `ask_user` is waiting for the user's answer.
    case awaitingAnswer(callID: String)
    /// `exit_plan_mode` is waiting for the user to approve the plan or ask for changes.
    case awaitingPlanApproval(callID: String)
}

/// Why a run ended. Every ending leaves the session valid, so the next message continues it.
public enum RunEnding: Sendable, Equatable {
    case completed
    /// The model hit its output limit; the UI offers Continue.
    case lengthLimit
    case contentFiltered
    /// Paused, not failed: the UI offers Continue.
    case iterationCap
    case stopped
    /// The same call a fourth time.
    case repeatedCall(String)
    case failed(String)
}

public enum AgentEvent: Sendable, Equatable {
    /// First event of a run. Its checkpoints, if it changes files, are filed under this id.
    case runStarted(RunID)
    case stateChanged(AgentState)
    case textDelta(String)
    case reasoningDelta(String)
    /// The turn is being resent after a transient failure: drop the streamed text and calls of this turn.
    case turnRestarted
    /// The finished assistant text of a turn, once.
    case assistantMessage(String)
    case toolCallStarted(id: String, name: String)
    case toolCallArguments(id: String, name: String, arguments: String)
    case toolCallFinished(id: String, name: String, output: ToolOutput)
    /// Live output of a running tool, for the transcript only.
    case toolCallOutput(id: String, chunk: String)
    /// The run is paused until `AgentSession.resolveApproval` is called for this call.
    case approvalRequested(ApprovalRequest)
    /// The run is paused until `AgentSession.answerQuestion` is called for this call.
    case questionAsked(UserQuestion)
    /// The model submitted a plan; the run is paused until `AgentSession.resolvePlan` is called for this call.
    case planProposed(callID: String, plan: String)
    /// The model wrote a tool call that could not be read; it has been told and will try again.
    case unreadableToolCall(detail: String)
    /// The model changed its checklist.
    case todosUpdated([TodoItem])
    case usage(TokenUsage)
    /// The conversation was shortened to fit the window. The host's transcript is unaffected.
    case compacted(CompactionReport)
    case runEnded(RunEnding)
}
