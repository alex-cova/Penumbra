// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/HyperEdgeCycleDetector.java

import Foundation

package final class org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeCycleDetector {
    private init() {}

    package static func detectCycles(
        _ segments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment],
        _ criticalOnly: Bool,
        _ random: Any? = nil
    ) -> [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] {
        var result: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] = []
        var sources = ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>()
        var sinks = ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>()

        var markBySegment: [ObjectIdentifier: Int] = [:]
        var inWeightBySegment: [ObjectIdentifier: Int] = [:]
        var outWeightBySegment: [ObjectIdentifier: Int] = [:]
        var criticalInWeightBySegment: [ObjectIdentifier: Int] = [:]
        var criticalOutWeightBySegment: [ObjectIdentifier: Int] = [:]

        initialize(
            segments,
            &sources,
            &sinks,
            criticalOnly,
            &markBySegment,
            &inWeightBySegment,
            &outWeightBySegment,
            &criticalInWeightBySegment,
            &criticalOutWeightBySegment
        )

        computeLinearOrderingMarks(
            segments,
            &sources,
            &sinks,
            criticalOnly,
            random,
            &markBySegment,
            &inWeightBySegment,
            &outWeightBySegment,
            &criticalInWeightBySegment,
            &criticalOutWeightBySegment
        )

        for source in segments {
            let sourceMark = markBySegment[ObjectIdentifier(source)] ?? 0
            let outgoing = source.getOutgoingSegmentDependencies()
            for outDependency in outgoing {
                if !criticalOnly || outDependency.getType() == .CRITICAL {
                    guard let target = outDependency.getTarget() else {
                        continue
                    }

                    let targetMark = markBySegment[ObjectIdentifier(target)] ?? 0
                    if sourceMark > targetMark {
                        result.append(outDependency)
                    }
                }
            }
        }

        return result
    }

    package static func initialize(
        _ segments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment],
        _ sources: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ sinks: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ criticalOnly: Bool,
        _ markBySegment: inout [ObjectIdentifier: Int],
        _ inWeightBySegment: inout [ObjectIdentifier: Int],
        _ outWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalInWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalOutWeightBySegment: inout [ObjectIdentifier: Int]
    ) {
        var nextMark = -1

        for segment in segments {
            let key = ObjectIdentifier(segment)
            markBySegment[key] = nextMark
            nextMark -= 1

            let criticalIncoming = segment.getIncomingSegmentDependencies()
                .filter { $0.getType() == .CRITICAL }
                .reduce(0) { $0 + $1.getWeight() }

            let criticalOutgoing = segment.getOutgoingSegmentDependencies()
                .filter { $0.getType() == .CRITICAL }
                .reduce(0) { $0 + $1.getWeight() }

            var inWeight = criticalIncoming
            var outWeight = criticalOutgoing

            if !criticalOnly {
                inWeight = segment.getIncomingSegmentDependencies()
                    .reduce(0) { $0 + $1.getWeight() }
                outWeight = segment.getOutgoingSegmentDependencies()
                    .reduce(0) { $0 + $1.getWeight() }
            }

            inWeightBySegment[key] = inWeight
            criticalInWeightBySegment[key] = criticalIncoming
            outWeightBySegment[key] = outWeight
            criticalOutWeightBySegment[key] = criticalOutgoing

            if outWeight == 0 {
                sinks.append(segment)
            } else if inWeight == 0 {
                sources.append(segment)
            }
        }
    }

    package static func computeLinearOrderingMarks(
        _ segments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment],
        _ sources: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ sinks: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ criticalOnly: Bool,
        _ random: Any?,
        _ markBySegment: inout [ObjectIdentifier: Int],
        _ inWeightBySegment: inout [ObjectIdentifier: Int],
        _ outWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalInWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalOutWeightBySegment: inout [ObjectIdentifier: Int]
    ) {
        var unprocessed = segments.sorted {
            (markBySegment[ObjectIdentifier($0)] ?? 0) < (markBySegment[ObjectIdentifier($1)] ?? 0)
        }
        var maxSegments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment] = []

        let markBase = segments.count
        var nextSinkMark = markBase - 1
        var nextSourceMark = markBase + 1
        var seededRandomState = random.map(seed(from:))

        while !unprocessed.isEmpty {
            while !sinks.isEmpty {
                let sink = sinks.removeFirst()
                removeFromUnprocessed(sink, &unprocessed)
                markBySegment[ObjectIdentifier(sink)] = nextSinkMark
                nextSinkMark -= 1

                updateNeighbors(
                    sink,
                    &sources,
                    &sinks,
                    criticalOnly,
                    &markBySegment,
                    &inWeightBySegment,
                    &outWeightBySegment,
                    &criticalInWeightBySegment,
                    &criticalOutWeightBySegment
                )
            }

            while !sources.isEmpty {
                let source = sources.removeFirst()
                removeFromUnprocessed(source, &unprocessed)
                markBySegment[ObjectIdentifier(source)] = nextSourceMark
                nextSourceMark += 1

                updateNeighbors(
                    source,
                    &sources,
                    &sinks,
                    criticalOnly,
                    &markBySegment,
                    &inWeightBySegment,
                    &outWeightBySegment,
                    &criticalInWeightBySegment,
                    &criticalOutWeightBySegment
                )
            }

            var maxOutflow = Int.min
            for segment in unprocessed {
                let key = ObjectIdentifier(segment)

                if !criticalOnly,
                   (criticalOutWeightBySegment[key] ?? 0) > 0,
                   (criticalInWeightBySegment[key] ?? 0) <= 0
                {
                    maxSegments.removeAll(keepingCapacity: true)
                    maxSegments.append(segment)
                    break
                }

                let outflow = (outWeightBySegment[key] ?? 0) - (inWeightBySegment[key] ?? 0)
                if outflow >= maxOutflow {
                    if outflow > maxOutflow {
                        maxSegments.removeAll(keepingCapacity: true)
                        maxOutflow = outflow
                    }
                    maxSegments.append(segment)
                }
            }

            if !maxSegments.isEmpty {
                let index = nextRandomInt(maxSegments.count, random, &seededRandomState)
                let maxNode = maxSegments[index]
                removeFromUnprocessed(maxNode, &unprocessed)
                markBySegment[ObjectIdentifier(maxNode)] = nextSourceMark
                nextSourceMark += 1

                updateNeighbors(
                    maxNode,
                    &sources,
                    &sinks,
                    criticalOnly,
                    &markBySegment,
                    &inWeightBySegment,
                    &outWeightBySegment,
                    &criticalInWeightBySegment,
                    &criticalOutWeightBySegment
                )
                maxSegments.removeAll(keepingCapacity: true)
            }
        }

        let shiftBase = segments.count + 1
        for node in segments {
            let key = ObjectIdentifier(node)
            if let mark = markBySegment[key], mark < markBase {
                markBySegment[key] = mark + shiftBase
            }
        }
    }

    package static func updateNeighbors(
        _ node: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ sources: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ sinks: inout ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>,
        _ criticalOnly: Bool,
        _ markBySegment: inout [ObjectIdentifier: Int],
        _ inWeightBySegment: inout [ObjectIdentifier: Int],
        _ outWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalInWeightBySegment: inout [ObjectIdentifier: Int],
        _ criticalOutWeightBySegment: inout [ObjectIdentifier: Int]
    ) {
        for dep in node.getOutgoingSegmentDependencies() {
            if !criticalOnly || dep.getType() == .CRITICAL {
                guard let target = dep.getTarget() else {
                    continue
                }

                let targetKey = ObjectIdentifier(target)
                if (markBySegment[targetKey] ?? 0) < 0, dep.getWeight() > 0 {
                    inWeightBySegment[targetKey] = (inWeightBySegment[targetKey] ?? 0) - dep.getWeight()
                    if dep.getType() == .CRITICAL {
                        criticalInWeightBySegment[targetKey] =
                            (criticalInWeightBySegment[targetKey] ?? 0) - dep.getWeight()
                    }

                    if (inWeightBySegment[targetKey] ?? 0) <= 0, (outWeightBySegment[targetKey] ?? 0) > 0 {
                        sources.append(target)
                    }
                }
            }
        }

        for dep in node.getIncomingSegmentDependencies() {
            if !criticalOnly || dep.getType() == .CRITICAL {
                guard let source = dep.getSource() else {
                    continue
                }

                let sourceKey = ObjectIdentifier(source)
                if (markBySegment[sourceKey] ?? 0) < 0, dep.getWeight() > 0 {
                    outWeightBySegment[sourceKey] = (outWeightBySegment[sourceKey] ?? 0) - dep.getWeight()
                    if dep.getType() == .CRITICAL {
                        criticalOutWeightBySegment[sourceKey] =
                            (criticalOutWeightBySegment[sourceKey] ?? 0) - dep.getWeight()
                    }

                    if (outWeightBySegment[sourceKey] ?? 0) <= 0, (inWeightBySegment[sourceKey] ?? 0) > 0 {
                        sinks.append(source)
                    }
                }
            }
        }
    }

    package static func removeFromUnprocessed(
        _ segment: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ unprocessed: inout [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        if let index = unprocessed.firstIndex(where: { $0 === segment }) {
            unprocessed.remove(at: index)
        }
    }

    package static func nextRandomInt(_ bound: Int, _ random: Any?, _ seededState: inout UInt64?) -> Int {
        if bound <= 1 {
            return 0
        }

        if var state = seededState {
            state = 2862933555777941757 &* state &+ 3037000493
            seededState = state
            let upper53 = state >> 11
            let unit = Double(upper53) / Double(1 << 53)
            let index = Int(unit * Double(bound))
            return min(index, bound - 1)
        }

        if let rng = random {
            seededState = seed(from: rng)
            return nextRandomInt(bound, rng, &seededState)
        }

        return Int.random(in: 0..<bound)
    }

    package static func seed(from value: Any) -> UInt64 {
        switch value {
        case let v as UInt64: return v
        case let v as UInt32: return UInt64(v)
        case let v as UInt: return UInt64(v)
        case let v as Int64: return UInt64(bitPattern: v)
        case let v as Int32: return UInt64(bitPattern: Int64(v))
        case let v as Int: return UInt64(bitPattern: Int64(v))
        case let v as Double: return v.bitPattern
        case let v as Float: return UInt64(v.bitPattern)
        case let v as String:
            return UInt64(bitPattern: Int64(v.hashValue))
        default:
            return UInt64(bitPattern: Int64(String(describing: value).hashValue))
        }
    }
}
