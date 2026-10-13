import Foundation

/// How much of one line a run executed.
public enum JavaLineCoverage: UInt8, Codable, Sendable, Equatable {
    /// Every instruction and branch of the line ran.
    case covered
    /// Some did and some did not (a branch not taken, a short-circuited operand).
    case partial
    /// None of the line ran.
    case missed
}

/// A missed and a covered count, JaCoCo's `<counter>`.
public struct JavaCoverageCounter: Codable, Sendable, Equatable {
    public var missed: Int
    public var covered: Int

    public init(missed: Int = 0, covered: Int = 0) {
        self.missed = missed
        self.covered = covered
    }

    public var total: Int { missed + covered }

    /// Covered over total, `nil` when there is nothing to cover.
    public var ratio: Double? { total == 0 ? nil : Double(covered) / Double(total) }

    /// `ratio` as 0...100, rounded down so a 99.6 % file never reads as complete.
    public var percent: Int? { total == 0 ? nil : covered * 100 / total }

    public static func + (lhs: JavaCoverageCounter, rhs: JavaCoverageCounter) -> JavaCoverageCounter {
        JavaCoverageCounter(missed: lhs.missed + rhs.missed, covered: lhs.covered + rhs.covered)
    }
}

/// The counters JaCoCo keeps for a package, class, method or source file.
public struct JavaCoverageTotals: Codable, Sendable, Equatable {
    public var instructions = JavaCoverageCounter()
    public var branches = JavaCoverageCounter()
    public var lines = JavaCoverageCounter()
    public var methods = JavaCoverageCounter()
    public var classes = JavaCoverageCounter()

    public init() {}

    public static func + (lhs: JavaCoverageTotals, rhs: JavaCoverageTotals) -> JavaCoverageTotals {
        var result = JavaCoverageTotals()
        result.instructions = lhs.instructions + rhs.instructions
        result.branches = lhs.branches + rhs.branches
        result.lines = lhs.lines + rhs.lines
        result.methods = lhs.methods + rhs.methods
        result.classes = lhs.classes + rhs.classes
        return result
    }
}

/// One line that has code on it, as JaCoCo reports it.
public struct JavaCoverageLine: Codable, Sendable, Equatable {
    /// 1-based, as in the source file.
    public var number: Int
    public var status: JavaLineCoverage
    public var missedInstructions: Int
    public var coveredInstructions: Int
    public var missedBranches: Int
    public var coveredBranches: Int

    public init(
        number: Int,
        missedInstructions: Int,
        coveredInstructions: Int,
        missedBranches: Int = 0,
        coveredBranches: Int = 0
    ) {
        self.number = number
        self.missedInstructions = missedInstructions
        self.coveredInstructions = coveredInstructions
        self.missedBranches = missedBranches
        self.coveredBranches = coveredBranches
        // JaCoCo's own rule (`LineImpl.getStatus`): nothing covered is missed, nothing missed is
        // covered, anything between is partial.
        if coveredInstructions == 0, coveredBranches == 0 {
            status = .missed
        } else if missedInstructions == 0, missedBranches == 0 {
            status = .covered
        } else {
            status = .partial
        }
    }
}

/// A run of adjacent lines of one status: what the editor paints.
public struct JavaCoverageBand: Sendable, Equatable {
    /// 1-based, inclusive.
    public var lines: ClosedRange<Int>
    public var status: JavaLineCoverage

    public init(lines: ClosedRange<Int>, status: JavaLineCoverage) {
        self.lines = lines
        self.status = status
    }
}

/// What a run covered in one source file.
public struct JavaCoverageSourceFile: Codable, Sendable, Equatable {
    /// The file's name, `Order.java`.
    public var name: String
    /// The package as written in Java, `com.example.shop` (empty for the default package).
    public var packageName: String
    /// The file in the project, when it could be found.
    public var url: URL?
    /// Lines that have code, sorted by number.
    public var lines: [JavaCoverageLine]
    public var totals: JavaCoverageTotals

    public init(
        name: String, packageName: String, url: URL? = nil,
        lines: [JavaCoverageLine], totals: JavaCoverageTotals = JavaCoverageTotals()
    ) {
        self.name = name
        self.packageName = packageName
        self.url = url
        self.lines = lines.sorted { $0.number < $1.number }
        self.totals = totals
    }

    /// `com/example/shop/Order.java`: the key a source lookup uses.
    public var relativePath: String {
        packageName.isEmpty ? name : packageName.replacingOccurrences(of: ".", with: "/") + "/" + name
    }

    /// The status of `line` (1-based), `nil` when the line has no code.
    public func status(atLine line: Int) -> JavaLineCoverage? {
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let number = lines[middle].number
            if number == line { return lines[middle].status }
            if number < line { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// Adjacent lines of one status merged, so painting is bounded by bands, not lines.
    public var bands: [JavaCoverageBand] {
        var result: [JavaCoverageBand] = []
        for line in lines {
            if let last = result.last, last.status == line.status, last.lines.upperBound + 1 == line.number {
                result[result.count - 1].lines = last.lines.lowerBound...line.number
            } else {
                result.append(JavaCoverageBand(lines: line.number...line.number, status: line.status))
            }
        }
        return result
    }

    /// The first line (1-based) after `line` that a run did not fully execute, wrapping to the
    /// start; `nil` when every line is covered.
    public func nextUncovered(after line: Int) -> Int? {
        let uncovered = lines.filter { $0.status != .covered }
        return uncovered.first { $0.number > line }?.number ?? uncovered.first?.number
    }

    /// The last line before `line` that was not fully executed, wrapping to the end.
    public func previousUncovered(before line: Int) -> Int? {
        let uncovered = lines.filter { $0.status != .covered }
        return uncovered.last { $0.number < line }?.number ?? uncovered.last?.number
    }
}

/// A class's counters; the source file it came from is `sourceFileName` in its package.
public struct JavaCoverageClass: Codable, Sendable, Equatable {
    /// `com/example/shop/Order$Line`, as in the class file.
    public var binaryName: String
    public var sourceFileName: String?
    public var totals: JavaCoverageTotals

    public init(binaryName: String, sourceFileName: String? = nil, totals: JavaCoverageTotals = JavaCoverageTotals()) {
        self.binaryName = binaryName
        self.sourceFileName = sourceFileName
        self.totals = totals
    }

    /// `Order.Line`: the simple name with nesting shown by dots.
    public var displayName: String {
        let simple = binaryName.split(separator: "/").last.map(String.init) ?? binaryName
        return simple.replacingOccurrences(of: "$", with: ".")
    }
}

public struct JavaCoveragePackage: Codable, Sendable, Equatable {
    /// `com.example.shop`; empty for the default package.
    public var name: String
    public var classes: [JavaCoverageClass]
    public var sourceFiles: [JavaCoverageSourceFile]
    public var totals: JavaCoverageTotals

    public init(
        name: String, classes: [JavaCoverageClass] = [], sourceFiles: [JavaCoverageSourceFile] = [],
        totals: JavaCoverageTotals = JavaCoverageTotals()
    ) {
        self.name = name
        self.classes = classes
        self.sourceFiles = sourceFiles
        self.totals = totals
    }
}

/// What one coverage run measured, read from a JaCoCo XML report.
public struct JavaCoverageReport: Codable, Sendable, Equatable {
    public var name: String
    public var packages: [JavaCoveragePackage]
    public var totals: JavaCoverageTotals

    public init(name: String = "", packages: [JavaCoveragePackage] = [], totals: JavaCoverageTotals = JavaCoverageTotals()) {
        self.name = name
        self.packages = packages
        self.totals = totals
    }

    /// Every source file of every package.
    public var sourceFiles: [JavaCoverageSourceFile] { packages.flatMap(\.sourceFiles) }

    /// The coverage of the file at `url`, by the URL the lookup resolved.
    public func sourceFile(at url: URL) -> JavaCoverageSourceFile? {
        let target = url.standardizedFileURL.path
        return sourceFiles.first { $0.url?.standardizedFileURL.path == target }
    }

    /// The source file of `package/Name.java`, for a report that was not resolved to project files.
    public func sourceFile(relativePath: String) -> JavaCoverageSourceFile? {
        sourceFiles.first { $0.relativePath == relativePath }
    }

    /// The report restricted to packages named by `prefixes` (`com.acme` keeps `com.acme` and
    /// `com.acme.shop`; a package whose name only starts with the same letters is not kept). Totals
    /// are summed again from what is kept. An empty list keeps everything.
    public func filtered(toPackagePrefixes prefixes: [String]) -> JavaCoverageReport {
        let wanted = prefixes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return self }
        let kept = packages.filter { package in
            wanted.contains { package.name == $0 || package.name.hasPrefix($0 + ".") }
        }
        var copy = self
        copy.packages = kept
        copy.totals = kept.reduce(JavaCoverageTotals()) { $0 + $1.totals }
        return copy
    }

    /// A copy with every source file's `url` taken from `lookup(relativePath)`.
    public func resolvingSources(_ lookup: (String) -> URL?) -> JavaCoverageReport {
        var copy = self
        for packageIndex in copy.packages.indices {
            for fileIndex in copy.packages[packageIndex].sourceFiles.indices {
                let file = copy.packages[packageIndex].sourceFiles[fileIndex]
                copy.packages[packageIndex].sourceFiles[fileIndex].url = lookup(file.relativePath)
            }
        }
        return copy
    }
}
