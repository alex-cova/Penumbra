import Foundation

/// Retry options are task-local. The planner only accepts roots and selectors the caller has verified.
public enum GradleTestRetryPlan {
    public struct Target: Hashable, Sendable {
        public let task: String
        public let filter: String

        public init(task: String, filter: String) {
            self.task = task
            self.filter = filter
        }
    }

    public struct Invocation: Sendable, Equatable {
        public let tasks: [String]
        public let arguments: [String]
    }

    public static func supportsTaskRerun(_ version: String?) -> Bool {
        version.map { ["7.6.4", "8.14.5", "9.9.2"].contains($0) } ?? false
    }

    public static func complete(tasks: [String], arguments: [String]) -> Invocation? {
        let selected = tasks.filter { $0 != "--rerun" }
        guard !selected.isEmpty, selected.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("*") }) else { return nil }
        return Invocation(tasks: selected.flatMap { [$0, "--rerun"] }, arguments: arguments)
    }

    public static func granular(targets: Set<Target>, arguments: [String]) -> [Invocation] {
        let shared = droppingSelectors(arguments)
        let valid = targets.filter { $0.task.hasPrefix(":") && !$0.filter.isEmpty && !$0.filter.contains("*") }
        let grouped = Dictionary(grouping: valid, by: \.task)
        return grouped.keys.sorted().map { task in
            let filters = (grouped[task] ?? []).map(\.filter).sorted()
            return Invocation(tasks: [task, "--rerun"], arguments: filters.flatMap { ["--tests", $0] } + shared)
        }
    }

    static func droppingSelectors(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skip = false
        for argument in arguments {
            if skip { skip = false; continue }
            if argument == "--tests" { skip = true; continue }
            if argument.hasPrefix("--tests=") || argument == "--rerun" { continue }
            result.append(argument)
        }
        return result
    }
}
