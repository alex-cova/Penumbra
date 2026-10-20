// Ported from Pele src/svg/shapes.ts @ 8603bf3 (MIT, Copyright (c) 2026 kepano). See Packages/Luna/NOTICE.
//
// Per-shape `span` rules: how much of the side that edges meet may be shared
// out between them, measured across the flow; 0 keeps them all at its middle.
// Luna's shape names are mapped to Pele's through Pele's flowchart alias table
// (src/diagrams/flowchart/shapes.ts): rectangle->rect, diamond->diam,
// hexagon->hex, stadium->stadium, circle->circle, subroutine->fr-rect,
// doublecircle->dbl-circ, cylinder->cyl, asymmetric->odd, trapezoid->trap-b,
// trapezoid-alt->trap-t, parallelogram->lean-r, parallelogram-alt->lean-l,
// state-start->sm-circ, state-end->fr-circ.
import Foundation

private let shapeCorner = 12.0

/// The span for a Luna node shape of size w by h.
/// `sideways` is true when the flow runs left-to-right (width and height swap roles).
/// Unknown shapes get 0: their edges meet at the middle of the side.
public func shapeSpan(shape: String, w: Double, h: Double, sideways: Bool) -> Double {
    let a = sideways ? h : w
    switch shape {
    case "diamond":
        // diam
        return a * 0.6
    case "circle", "doublecircle", "stateStart", "stateEnd":
        // circle, dbl-circ, sm-circ, fr-circ: roundSpan
        return a * 0.6
    case "hexagon":
        // hex
        return sideways ? h * 0.5 : w - h / 2 - shapeCorner
    case "stadium":
        return sideways ? h * 0.6 : w - h
    case "cylinder":
        // cyl
        return sideways ? h - 2 * shapeCorner - 12 : w * 0.6
    case "asymmetric":
        // odd: flatAcross(() => 0)
        return sideways ? 0 : w - 2 * shapeCorner
    case "trapezoid", "trapezoidAlt", "leanRight", "leanLeft":
        // trap-b, trap-t, lean-r, lean-l: flatAcross((h) => h / 4)
        return sideways ? 0 : w - 2 * (h / 4) - 2 * shapeCorner
    default:
        // rect, rounded, subroutine (fr-rect) and the rest: flat
        return max(0, a - 2 * shapeCorner)
    }
}
