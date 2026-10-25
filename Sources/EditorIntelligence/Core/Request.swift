import Foundation

/// How a language feature was triggered. Used by feature contexts (completion, hover,
/// navigation) to distinguish explicit invocations from keystroke- or idle-driven ones.
public enum RequestTrigger: Hashable, Sendable {
    case manual
    case keystroke(String)
    case idle
}
