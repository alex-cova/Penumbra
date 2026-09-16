// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/wrapping/MSDCutIndexHeuristic.java

import Foundation

package class org_eclipse_elk_alg_layered_intermediate_wrapping_MSDCutIndexHeuristic: org_eclipse_elk_alg_layered_intermediate_wrapping_ICutIndexCalculator {
    package static let WRAPPING_CUTTING_MSD_FREEDOM_KEY = "org.eclipse.elk.layered.wrapping.cutting.msd.freedom"

    package init() {}

    package func guaranteeValid() -> Bool {
        false
    }

    package func getCutIndexes(
        _ graph: LGraph,
        _ gs: org_eclipse_elk_alg_layered_intermediate_wrapping_GraphStats
    ) -> [Int] {
        // Minimize the max of the sums of the widths.
        let widths = gs.getWidths()
        let heights = gs.getHeights()

        // Record the accumulated width at each index of the original layering.
        var widthAtIndex = Array(repeating: 0.0, count: widths.count)
        widthAtIndex[0] = widths[0]
        var total = widths[0]
        if widths.count > 1 {
            for i in 1..<widths.count {
                widthAtIndex[i] = widthAtIndex[i - 1] + widths[i]
                total += widths[i]
            }
        }

        // Initial guess on a good number of cuts.
        let cutCnt = org_eclipse_elk_alg_layered_intermediate_wrapping_ARDCutIndexHeuristic.getChunkCount(gs) - 1
        let freedom = graph.getProperty(Self.WRAPPING_CUTTING_MSD_FREEDOM_KEY) as? Int ?? 0

        var bestMaxScale = -Double.infinity
        var bestCuts: [Int] = []

        // Now find the best set of cut indexes.
        let minM = max(0, cutCnt - freedom)
        let maxM = min(gs.longestPath - 1, cutCnt + freedom)

        if minM <= maxM {
            for m in minM...maxM {
                // Calculate cuts.
                let rowSum = total / Double(m + 1)
                var sumSoFar = 0.0
                var index = 1
                var cuts: [Int] = []

                // Maximum of any row width.
                var width = -Double.infinity
                var lastCutWidth = 0.0
                // Sum of the row height maximums.
                var height = 0.0
                var rowHeightMax = heights[0]

                if m == 0 {
                    width = total
                    height = gs.getMaxHeight()
                } else {
                    while index < gs.longestPath {
                        if widthAtIndex[index - 1] - sumSoFar >= rowSum {
                            // Cut before index.
                            cuts.append(index)

                            // Update state.
                            width = max(width, widthAtIndex[index - 1] - lastCutWidth)
                            height += rowHeightMax

                            sumSoFar += (widthAtIndex[index - 1] - sumSoFar)
                            lastCutWidth = widthAtIndex[index - 1]
                            rowHeightMax = heights[index]
                        }

                        rowHeightMax = max(rowHeightMax, heights[index])

                        index += 1
                    }

                    // Add heights of last row.
                    height += rowHeightMax
                }

                // Are they better?
                let maxScale = min(1.0 / width, (1.0 / gs.dar) / height)

                if maxScale > bestMaxScale {
                    bestMaxScale = maxScale
                    bestCuts = cuts
                }
            }
        }

        return bestCuts
    }
}
