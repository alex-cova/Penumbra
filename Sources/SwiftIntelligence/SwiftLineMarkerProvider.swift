import EditorIntelligence
import Foundation

/// Gutter markers for Swift: ↑ on a member that overrides or implements, ↓ on a type or member
/// something below it overrides or implements, and a mark on a method's call of itself.
public struct SwiftLineMarkerProvider: LineMarkerProviding {
    private let index: SwiftIndex

    public init(index: SwiftIndex) {
        self.index = index
    }

    public func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? {
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        if let fileURL { await index.noteOpenDocument(url: fileURL, text: source) }
        if Task.isCancelled { return nil }
        var markers: [LineMarker] = []
        var seen = Set<String>()
        func add(_ kind: LineMarkerKind, bytes: Range<Int>, tooltip: String) {
            guard kinds.contains(kind) else { return }
            let position = parsed.text.position(atByte: bytes.lowerBound)
            guard seen.insert("\(kind.rawValue):\(position.line)").inserted else { return }
            markers.append(LineMarker(
                kind: kind, line: position.line + 1, anchorUTF16Offset: position.utf16Offset, tooltip: tooltip
            ))
        }

        // Every type and extension of the file, nested ones included.
        var types: [SwiftFileModel.Declaration] = []
        var pending = parsed.model.declarations
        while let declaration = pending.popLast() {
            if declaration.kind.isNominalType || declaration.kind == .extension {
                types.append(declaration)
                pending.append(contentsOf: declaration.members)
            }
        }
        types.sort { $0.nameBytes.lowerBound < $1.nameBytes.lowerBound }

        for type in types {
            if Task.isCancelled { return nil }
            // What sits above: the members of every direct supertype and what they inherit.
            let supers = await index.supertypes(of: type.name, visibleFrom: fileURL)
            var above: [String: SwiftIndex.MemberRef] = [:]
            for name in supers {
                for ref in await index.members(ofType: name, visibleFrom: fileURL) where ref.owner != type.name {
                    let key = Self.key(ref.declaration)
                    if above[key] == nil { above[key] = ref }
                }
            }
            // What sits below: the members every descendant declares itself.
            let below = await index.descendants(of: type.name, visibleFrom: fileURL)
            var belowCount: [String: Int] = [:]
            for descendant in below {
                for member in descendant.declaration.members {
                    belowCount[Self.key(member), default: 0] += 1
                }
            }
            if !below.isEmpty, type.kind != .extension, type.kind.isNominalType {
                let names = Set(below.map(\.declaration.name)).count
                if type.kind == .protocol {
                    add(.implemented, bytes: type.nameBytes, tooltip: "Implemented in \(names) type\(names == 1 ? "" : "s")")
                } else if type.kind == .class {
                    add(.overridden, bytes: type.nameBytes, tooltip: "Subclassed by \(names) type\(names == 1 ? "" : "s")")
                }
            }
            for member in type.members where member.kind == .function || member.kind == .property {
                let key = Self.key(member)
                if let target = above[key] {
                    let isRequirement = await isProtocol(target.owner, file: fileURL)
                    let who = "\(target.owner).\(member.name)"
                    if isRequirement {
                        add(.implementing, bytes: member.nameBytes, tooltip: "Implements \(who)")
                    } else if member.isOverride || type.kind == .class {
                        add(.overriding, bytes: member.nameBytes, tooltip: "Overrides \(who)")
                    }
                }
                if let count = belowCount[key], count > 0 {
                    if type.kind == .protocol {
                        add(.implemented, bytes: member.nameBytes, tooltip: "Implemented in \(count) type\(count == 1 ? "" : "s")")
                    } else if type.kind == .class {
                        add(.overridden, bytes: member.nameBytes, tooltip: "Overridden in \(count) type\(count == 1 ? "" : "s")")
                    }
                }
                if member.kind == .function, kinds.contains(.recursiveCall) {
                    let labels = member.parameters.map { $0.label ?? "_" }
                    for use in parsed.model.uses where use.isCall && use.name == member.name
                        && member.bodyBytes.contains(use.bytes.lowerBound) && use.callLabels == labels {
                        switch use.role {
                        case .value:
                            add(.recursiveCall, bytes: use.bytes, tooltip: "Recursive call")
                        case .member(let chain) where chain.steps.isEmpty:
                            if case .selfValue = chain.base { add(.recursiveCall, bytes: use.bytes, tooltip: "Recursive call") }
                        default:
                            break
                        }
                    }
                }
            }
        }
        markers.sort { $0.line < $1.line }
        return markers
    }

    public func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] {
        []
    }

    private static func key(_ declaration: SwiftFileModel.Declaration) -> String {
        "\(declaration.kind == .property ? "p" : "f"):\(declaration.name):\(declaration.parameters.map { $0.label ?? "_" }.joined(separator: ","))"
    }

    private func isProtocol(_ name: String, file: URL?) async -> Bool {
        await index.types(named: name, visibleFrom: file).contains { $0.declaration.kind == .protocol }
    }
}
