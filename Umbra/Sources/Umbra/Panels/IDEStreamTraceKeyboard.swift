import Foundation

/// Arrow keys in the Stream Trace split view: up/down stay in a stage, left/right hop to the
/// neighbouring stage keeping the row when it exists.
enum IDEStreamTraceKeyboard {
    struct Cell: Equatable {
        var stage: Int
        var index: Int
    }

    static func move(
        _ selected: Cell?,
        stageCounts: [Int],
        dStage: Int,
        dIndex: Int
    ) -> Cell? {
        let nonempty = stageCounts.indices.filter { stageCounts[$0] > 0 }
        guard !nonempty.isEmpty else { return nil }
        if dIndex != 0 {
            let stage = selected?.stage ?? (dIndex > 0 ? nonempty.first! : nonempty.last!)
            guard nonempty.contains(stage) else { return nil }
            let items = Array(0..<stageCounts[stage])
            guard let next = IDEListNeighbor.move(selected?.index, in: items, by: dIndex) else { return nil }
            return Cell(stage: stage, index: next)
        }
        guard let nextStage = IDEListNeighbor.move(selected?.stage, in: nonempty, by: dStage) else { return nil }
        return Cell(stage: nextStage, index: min(selected?.index ?? 0, stageCounts[nextStage] - 1))
    }
}
