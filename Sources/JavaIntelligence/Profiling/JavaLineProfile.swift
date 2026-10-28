import Foundation

/// What each source line cost in a profile, for the hints an editor shows beside the code.
///
/// A frame of a stack is a method and the line it was executing, so the line of a caller is the line
/// of the call: a line's *total* is every sample that had a frame at that line anywhere on its stack
/// (the call and everything below it), and its *self* is the samples that ended there.
public struct JavaLineProfile: Sendable {
    public struct Cost: Equatable, Sendable {
        public var selfCount: Int
        public var totalCount: Int

        public init(selfCount: Int, totalCount: Int) {
            self.selfCount = selfCount
            self.totalCount = totalCount
        }
    }

    /// The samples the shares are of.
    public let totalSamples: Int
    private let costs: [String: [Int32: Cost]]
    /// Line costs by recorded source file (`/proj/Sources/spin/main.swift`), for profiles whose
    /// frames carry a file path (Swift time profiles; JFR frames carry none).
    private let fileCosts: [String: [Int32: Cost]]

    public init(totalSamples: Int = 0, costs: [String: [Int32: Cost]] = [:], fileCosts: [String: [Int32: Cost]] = [:]) {
        self.totalSamples = totalSamples
        self.costs = costs
        self.fileCosts = fileCosts
    }

    public var isEmpty: Bool { costs.isEmpty && fileCosts.isEmpty }

    /// The classes with costs, as binary names of top-level classes (`app.Order`, not `app.Order$Line`).
    public var classNames: [String] { Array(costs.keys) }

    /// The recorded source files with costs.
    public var filePaths: [String] { Array(fileCosts.keys) }

    /// Line (1-based) to cost, for a top-level class; nested, anonymous and lambda classes of it count.
    public func lines(ofClass className: String) -> [Int32: Cost] {
        costs[className] ?? [:]
    }

    /// Line (1-based) to cost, for a recorded source file.
    public func lines(ofFile path: String) -> [Int32: Cost] {
        fileCosts[path] ?? [:]
    }

    /// The top-level class a frame's class belongs to: `app.Order$Line` and
    /// `app.Order$$Lambda/0x…` are in `app.Order`'s file.
    public static func topLevelClass(of className: String) -> String {
        className.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? className
    }

    public static func build(from tree: JavaProfileTree, symbols: JavaProfileSymbols) -> JavaLineProfile {
        struct Key: Hashable {
            var className: String
            var line: Int32
        }
        struct FileKey: Hashable {
            var path: String
            var line: Int32
        }
        var costs: [String: [Int32: Cost]] = [:]
        var byFile: [String: [Int32: Cost]] = [:]
        var active: [Key: Int] = [:]
        var activeFiles: [FileKey: Int] = [:]
        var classOfMethod: [Int32: String] = [:]
        func keyOf(_ node: Int) -> Key? {
            let frame = tree.frame(of: node)
            guard frame >= 0 else { return nil }
            let info = symbols.frame(frame)
            guard info.line > 0 else { return nil }
            let className: String
            if let known = classOfMethod[info.method] {
                className = known
            } else {
                className = topLevelClass(of: symbols.methods[Int(info.method)].className)
                classOfMethod[info.method] = className
            }
            guard !className.isEmpty else { return nil }
            return Key(className: className, line: info.line)
        }
        func fileKeyOf(_ node: Int) -> FileKey? {
            let frame = tree.frame(of: node)
            guard frame >= 0 else { return nil }
            let info = symbols.frame(frame)
            guard info.line > 0 else { return nil }
            guard let path = symbols.sourcePath(ofFrame: frame), !path.isEmpty else { return nil }
            return FileKey(path: path, line: info.line)
        }

        // Entering a node adds its total at its line unless the same line is already on the path
        // (recursion, or two frames of one line), and leaving takes it off the path again.
        var stack: [(node: Int, leaving: Bool)] = [(JavaProfileTree.root, false)]
        while let (node, leaving) = stack.popLast() {
            if leaving {
                if let key = keyOf(node) { active[key, default: 1] -= 1 }
                if let fileKey = fileKeyOf(node) { activeFiles[fileKey, default: 1] -= 1 }
                continue
            }
            if let key = keyOf(node) {
                var cost = costs[key.className, default: [:]][key.line] ?? Cost(selfCount: 0, totalCount: 0)
                cost.selfCount += tree.selfCount(of: node)
                if active[key, default: 0] == 0 { cost.totalCount += tree.totalCount(of: node) }
                costs[key.className, default: [:]][key.line] = cost
                active[key, default: 0] += 1
                stack.append((node, true))
            } else if fileKeyOf(node) != nil {
                // A frame with a file but no class: the push still balances the pop above.
                stack.append((node, true))
            }
            if let fileKey = fileKeyOf(node) {
                var cost = byFile[fileKey.path, default: [:]][fileKey.line] ?? Cost(selfCount: 0, totalCount: 0)
                cost.selfCount += tree.selfCount(of: node)
                if activeFiles[fileKey, default: 0] == 0 { cost.totalCount += tree.totalCount(of: node) }
                byFile[fileKey.path, default: [:]][fileKey.line] = cost
                activeFiles[fileKey, default: 0] += 1
            }
            for child in tree.children(of: node) { stack.append((child, false)) }
        }
        return JavaLineProfile(totalSamples: tree.totalSamples, costs: costs, fileCosts: byFile)
    }
}
