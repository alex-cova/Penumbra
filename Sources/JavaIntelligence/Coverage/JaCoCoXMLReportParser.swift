import Foundation

/// Why a JaCoCo report could not be read.
public enum JaCoCoReportError: Error, Equatable, LocalizedError, Sendable {
    /// The file is not XML, or ends early.
    case malformed(String)
    /// The XML is fine but is not a JaCoCo `<report>`.
    case notAReport

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): return "The coverage report is not valid XML (\(detail))."
        case .notAReport: return "The file is not a JaCoCo coverage report."
        }
    }
}

/// Reads the XML `jacococli report --xml` writes into a ``JavaCoverageReport``.
///
/// The report starts with a `<!DOCTYPE>` naming `report.dtd` on JaCoCo's site; the parser never
/// resolves external entities, so nothing is fetched and a report read offline or sandboxed behaves
/// the same.
public enum JaCoCoXMLReportParser {
    /// - Parameter sourceLookup: maps `com/example/Order.java` to the file in the project, or `nil`.
    ///   Called once per source file, off the main actor like the parse itself.
    public static func parse(
        _ data: Data,
        sourceLookup: (String) -> URL? = { _ in nil }
    ) throws -> JavaCoverageReport {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw JaCoCoReportError.malformed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard delegate.sawReport else { throw JaCoCoReportError.notAReport }
        return delegate.report.resolvingSources(sourceLookup)
    }

    public static func parse(
        contentsOf url: URL,
        sourceLookup: (String) -> URL? = { _ in nil }
    ) throws -> JavaCoverageReport {
        try parse(Data(contentsOf: url, options: .mappedIfSafe), sourceLookup: sourceLookup)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var report = JavaCoverageReport()
        var sawReport = false

        private var stack: [String] = []
        private var currentPackage: JavaCoveragePackage?
        private var currentClass: JavaCoverageClass?
        private var currentFile: JavaCoverageSourceFile?
        private var fileLines: [JavaCoverageLine] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            let parent = stack.last
            stack.append(elementName)
            switch elementName {
            case "report":
                sawReport = true
                report.name = attributeDict["name"] ?? ""
            case "package":
                let name = (attributeDict["name"] ?? "").replacingOccurrences(of: "/", with: ".")
                currentPackage = JavaCoveragePackage(name: name)
            case "class":
                guard currentPackage != nil, let name = attributeDict["name"] else { return }
                currentClass = JavaCoverageClass(binaryName: name, sourceFileName: attributeDict["sourcefilename"])
            case "sourcefile":
                guard let currentPackage, let name = attributeDict["name"] else { return }
                currentFile = JavaCoverageSourceFile(name: name, packageName: currentPackage.name, lines: [])
                fileLines = []
            case "line":
                guard currentFile != nil, parent == "sourcefile",
                      let number = attributeDict["nr"].flatMap(Int.init) else { return }
                fileLines.append(JavaCoverageLine(
                    number: number,
                    missedInstructions: attributeDict["mi"].flatMap(Int.init) ?? 0,
                    coveredInstructions: attributeDict["ci"].flatMap(Int.init) ?? 0,
                    missedBranches: attributeDict["mb"].flatMap(Int.init) ?? 0,
                    coveredBranches: attributeDict["cb"].flatMap(Int.init) ?? 0
                ))
            case "counter":
                guard let type = attributeDict["type"],
                      let missed = attributeDict["missed"].flatMap(Int.init),
                      let covered = attributeDict["covered"].flatMap(Int.init) else { return }
                let counter = JavaCoverageCounter(missed: missed, covered: covered)
                switch parent {
                case "report": Self.assign(counter, type: type, to: &report.totals)
                case "package": if currentPackage != nil { Self.assign(counter, type: type, to: &currentPackage!.totals) }
                case "class": if currentClass != nil { Self.assign(counter, type: type, to: &currentClass!.totals) }
                case "sourcefile": if currentFile != nil { Self.assign(counter, type: type, to: &currentFile!.totals) }
                default: break
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            _ = stack.popLast()
            switch elementName {
            case "class":
                if let currentClass { currentPackage?.classes.append(currentClass) }
                currentClass = nil
            case "sourcefile":
                if var file = currentFile {
                    file.lines = fileLines.sorted { $0.number < $1.number }
                    currentPackage?.sourceFiles.append(file)
                }
                currentFile = nil
                fileLines = []
            case "package":
                if let currentPackage { report.packages.append(currentPackage) }
                currentPackage = nil
            default:
                break
            }
        }

        private static func assign(_ counter: JavaCoverageCounter, type: String, to totals: inout JavaCoverageTotals) {
            switch type {
            case "INSTRUCTION": totals.instructions = counter
            case "BRANCH": totals.branches = counter
            case "LINE": totals.lines = counter
            case "METHOD": totals.methods = counter
            case "CLASS": totals.classes = counter
            default: break // COMPLEXITY is not shown.
            }
        }
    }
}
