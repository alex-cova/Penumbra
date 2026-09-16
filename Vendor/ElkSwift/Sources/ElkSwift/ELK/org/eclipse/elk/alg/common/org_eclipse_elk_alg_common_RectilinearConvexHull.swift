/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

// MARK: - RectilinearConvexHull

package final class RectilinearConvexHull {

    package var hull: [Point] = []

    package var xMax1: Point? = nil
    package var xMax2: Point? = nil
    package var xMin1: Point? = nil
    package var xMin2: Point? = nil
    package var yMax1: Point? = nil
    package var yMax2: Point? = nil
    package var yMin1: Point? = nil
    package var yMin2: Point? = nil

    private init() { }

    package static func of(_ points: [Point]) -> RectilinearConvexHull {
        let rch = RectilinearConvexHull()

        for p in points {
            if rch.xMax1.map({ p.x >= $0.x }) ?? true {
                rch.xMax2 = rch.xMax1
                rch.xMax1 = p
            }
            if rch.xMin1.map({ p.x <= $0.x }) ?? true {
                rch.xMin2 = rch.xMin1
                rch.xMin1 = p
            }
            if rch.yMax1.map({ p.y >= $0.y }) ?? true {
                rch.yMax2 = rch.yMax1
                rch.yMax1 = p
            }
            if rch.yMin1.map({ p.y <= $0.y }) ?? true {
                rch.yMin2 = rch.yMin1
                rch.yMin1 = p
            }
        }

        var q1Points: [Point] = []
        var q4Points: [Point] = []
        var q2Points: [Point] = []
        var q3Points: [Point] = []

        let q1Handler = MaximalElementsEventHandler(.Q1)
        Scanline<Point>.execute(points, comparator: rightLowFirstComparator, eventHandler: { q1Handler.handle($0) })
        q1Points = q1Handler.points

        let q4Handler = MaximalElementsEventHandler(.Q4)
        Scanline<Point>.execute(points, comparator: rightHighFirstComparator, eventHandler: { q4Handler.handle($0) })
        q4Points = q4Handler.points

        let q2Handler = MaximalElementsEventHandler(.Q2)
        Scanline<Point>.execute(points, comparator: leftLowFirstComparator, eventHandler: { q2Handler.handle($0) })
        q2Points = q2Handler.points

        let q3Handler = MaximalElementsEventHandler(.Q3)
        Scanline<Point>.execute(points, comparator: leftHighFirstComparator, eventHandler: { q3Handler.handle($0) })
        q3Points = q3Handler.points

        addConcaveCorners(&q1Points, .Q1)
        addConcaveCorners(&q2Points, .Q2)
        addConcaveCorners(&q3Points, .Q3)
        addConcaveCorners(&q4Points, .Q4)

        var resultHull: [Point] = []
        resultHull.append(contentsOf: q1Points)
        resultHull.append(contentsOf: q2Points.reversed())
        resultHull.append(contentsOf: q3Points)
        resultHull.append(contentsOf: q4Points.reversed())

        rch.hull = resultHull

        return rch
    }

    package func getHull() -> [Point] {
        return hull
    }

    package func splitIntoRectangles() -> [ElkRectangle] {
        let handler = RectangleEventHandler(self)
        Scanline<Point>.execute(hull, comparator: Self.rightSpecialOrderComparator, eventHandler: { handler.handle($0) })

        var rectangles = handler.rects
        if let queued = handler.queued {
            rectangles.append(queued)
        }

        return rectangles
    }

    package static func addConcaveCorners(_ pts: inout [Point], _ q: Point.Quadrant) {
        guard pts.count >= 2 else { return }
        var i = 0
        while i < pts.count - 1 {
            let last = pts[i]
            let next = pts[i + 1]
            let p = Point(x: next.x, y: last.y, quadrant: q)
            var newP = p
            newP.convex = false
            pts.insert(newP, at: i + 1)
            i += 2 // skip the inserted point and move to next
        }
    }

    // MARK: - Comparators as closures

    package static let rightHighFirstComparator: (Point, Point) -> Bool = { p1, p2 in
        if p1.x == p2.x {
            return p2.y > p1.y
        } else {
            return p1.x < p2.x
        }
    }

    package static let rightLowFirstComparator: (Point, Point) -> Bool = { p1, p2 in
        if p1.x == p2.x {
            return p1.y < p2.y
        } else {
            return p1.x < p2.x
        }
    }

    package static let leftHighFirstComparator: (Point, Point) -> Bool = { p1, p2 in
        if p1.x == p2.x {
            return p2.y > p1.y
        } else {
            return p2.x < p1.x
        }
    }

    package static let leftLowFirstComparator: (Point, Point) -> Bool = { p1, p2 in
        if p1.x == p2.x {
            return p1.y < p2.y
        } else {
            return p2.x < p1.x
        }
    }

    package static let rightSpecialOrderComparator: (Point, Point) -> Bool = { p1, p2 in
        if p1.x == p2.x {
            if let q1 = p1.quadrant, let q2 = p2.quadrant {
                if q1 == q2 || Point.Quadrant.isBothLeftOrBothRight(q1, q2) {
                    let val = q1.isLeft() ? 1 : -1
                    if p1.convex && !p2.convex {
                        return val == 1
                    } else if !p1.convex && p2.convex {
                        return val != 1
                    }
                }
                return q1.rawValue < q2.rawValue
            }
            return false
        } else {
            return p1.x < p2.x
        }
    }

    // MARK: - Inner Event Handlers

    package class MaximalElementsEventHandler {
        var quadrant: Point.Quadrant
        var points: [Point] = []
        package var maximalY: Double
        package let compareFn: (Double, Double) -> Bool

        init(_ quadrant: Point.Quadrant) {
            self.quadrant = quadrant

            switch quadrant {
            case .Q1, .Q2:
                compareFn = { (d1, d2) in d1 < d2 }
                maximalY = Double.infinity
            case .Q3, .Q4:
                compareFn = { (d1, d2) in d1 > d2 }
                maximalY = -Double.infinity
            }
        }

        package func handle(_ p: Point) {
            if compareFn(p.y, maximalY) {
                points.append(Point(x: p.x, y: p.y, quadrant: quadrant))
                maximalY = p.y
            }
        }
    }

    package class RectangleEventHandler {
        var rects: [ElkRectangle] = []

        package var minY: Point? = nil
        package var maxY: Point? = nil

        package var lastX: Double
        package var queued: ElkRectangle? = nil
        package var queuedPnt: Point? = nil

        package weak var hullInstance: RectilinearConvexHull?

        init(_ hullInstance: RectilinearConvexHull) {
            self.hullInstance = hullInstance
            let x1 = hullInstance.xMin1?.x ?? 0
            let x2 = hullInstance.xMin2?.x ?? 0
            self.lastX = min(x1, x2)
        }

        package func handle(_ p: Point) {
            if let qPnt = queuedPnt, let q = queued,
               let qPntQuadrant = qPnt.quadrant, let pQuadrant = p.quadrant {
                if p.x != qPnt.x ||
                    Point.Quadrant.isOneLeftOneRight(qPntQuadrant, pQuadrant) {

                    rects.append(q)
                    lastX = q.x + q.width
                    queued = nil
                    queuedPnt = nil
                }
            }

            if let q = p.quadrant, q.isUpper() {
                minY = p
            } else {
                maxY = p
            }

            if let q = p.quadrant {
                let shouldQueue = (q == .Q1 && !p.convex) ||
                    (q == .Q2 && p.convex) ||
                    (q == .Q3 && p.convex) ||
                    (q == .Q4 && !p.convex)

                if shouldQueue {
                    if let minY = minY, let maxY = maxY {
                        let r = ElkRectangle(x: lastX, y: minY.y, width: p.x - lastX, height: maxY.y - minY.y)
                        queued = r
                        queuedPnt = p
                    }
                }
            }
        }
    }
}
