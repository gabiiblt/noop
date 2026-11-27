import Foundation

// A reader for the SVG path strings the body map is drawn from (`Strand/Resources/BodyGeometry.json`, converted from
// MuscleMap by Melih Colpan, MIT; see ATTRIBUTION.md). Pure and free of SwiftUI so it is testable without a screen:
// it turns a path string into absolute segments, and the view turns those into a `Path`.
//
// The paths use M, L, H, V, C, S, Q, T, A and Z, absolute or relative, with implicit repeats, numbers run together
// at their signs ("-18.95-22") and exponents ("1e-3"). Arcs are turned into cubic curves (at most a quarter turn
// each); their two flags may be written with no separator ("012.84" is 0, 1, then 2.84), as the artwork does.
//
// The artwork has about 360 arcs. An earlier version claimed it had none and stopped each path at its first one,
// which drew the body map in pieces: half the muscles were cut off where their outline first curved.

enum SVGPathSegment: Equatable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case cubic(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
    case quad(cx: Double, cy: Double, x: Double, y: Double)
    case close
}

enum SVGPathData {

    /// The path as absolute segments. A path that cannot be read past some point returns what was read up to it.
    static func parse(_ d: String) -> [SVGPathSegment] {
        var scanner = Scanner(Array(d.utf8))
        var out: [SVGPathSegment] = []
        var cur = (x: 0.0, y: 0.0)
        var start = (x: 0.0, y: 0.0)
        // The last control point, for S and T's reflection, and which kind it belongs to.
        var lastCubic: (x: Double, y: Double)?
        var lastQuad: (x: Double, y: Double)?
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            if scanner.atEnd { break }
            if let c = scanner.peekCommand() {
                command = c
                scanner.advance()
                if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                    out.append(.close)
                    cur = start
                    lastCubic = nil; lastQuad = nil
                    continue
                }
            } else if command == 0 || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                break   // numbers with no command to take them
            }
            let rel = command >= UInt8(ascii: "a")
            let up = rel ? command - 32 : command
            func abs(_ x: Double, _ y: Double) -> (Double, Double) { rel ? (cur.x + x, cur.y + y) : (x, y) }

            switch up {
            case UInt8(ascii: "M"):
                guard let x = scanner.number(), let y = scanner.number() else { return out }
                let p = abs(x, y)
                out.append(.move(x: p.0, y: p.1)); cur = (p.0, p.1); start = cur
                // Further pairs after a move are implicit line-tos.
                command = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "L"):
                guard let x = scanner.number(), let y = scanner.number() else { return out }
                let p = abs(x, y)
                out.append(.line(x: p.0, y: p.1)); cur = (p.0, p.1)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "H"):
                guard let x = scanner.number() else { return out }
                let nx = rel ? cur.x + x : x
                out.append(.line(x: nx, y: cur.y)); cur.x = nx
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "V"):
                guard let y = scanner.number() else { return out }
                let ny = rel ? cur.y + y : y
                out.append(.line(x: cur.x, y: ny)); cur.y = ny
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "C"):
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(),
                      let d2 = scanner.number(), let e = scanner.number(), let f = scanner.number() else { return out }
                let p1 = abs(a, b), p2 = abs(c, d2), p = abs(e, f)
                out.append(.cubic(c1x: p1.0, c1y: p1.1, c2x: p2.0, c2y: p2.1, x: p.0, y: p.1))
                lastCubic = (p2.0, p2.1); lastQuad = nil; cur = (p.0, p.1)
            case UInt8(ascii: "S"):
                guard let c = scanner.number(), let d2 = scanner.number(), let e = scanner.number(), let f = scanner.number() else { return out }
                // The first control point mirrors the last one about the current point, or is the current point.
                let r = lastCubic.map { (2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? (cur.x, cur.y)
                let p2 = abs(c, d2), p = abs(e, f)
                out.append(.cubic(c1x: r.0, c1y: r.1, c2x: p2.0, c2y: p2.1, x: p.0, y: p.1))
                lastCubic = (p2.0, p2.1); lastQuad = nil; cur = (p.0, p.1)
            case UInt8(ascii: "Q"):
                guard let a = scanner.number(), let b = scanner.number(), let c = scanner.number(), let d2 = scanner.number() else { return out }
                let p1 = abs(a, b), p = abs(c, d2)
                out.append(.quad(cx: p1.0, cy: p1.1, x: p.0, y: p.1))
                lastQuad = (p1.0, p1.1); lastCubic = nil; cur = (p.0, p.1)
            case UInt8(ascii: "T"):
                guard let c = scanner.number(), let d2 = scanner.number() else { return out }
                let r = lastQuad.map { (2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? (cur.x, cur.y)
                let p = abs(c, d2)
                out.append(.quad(cx: r.0, cy: r.1, x: p.0, y: p.1))
                lastQuad = (r.0, r.1); lastCubic = nil; cur = (p.0, p.1)
            case UInt8(ascii: "A"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let ex = scanner.number(), let ey = scanner.number() else { return out }
                let p = abs(ex, ey)
                out += arc(from: cur, to: (p.0, p.1), rx: rx, ry: ry, rotationDeg: rot,
                           largeArc: large, sweep: sweep)
                lastCubic = nil; lastQuad = nil; cur = (p.0, p.1)
            default:
                return out   // anything else: stop rather than guess
            }
        }
        return out
    }

    /// An elliptical arc as cubic curves, following the SVG specification's endpoint-to-centre conversion (F.6.5)
    /// and its out-of-range radii correction (F.6.6). A zero radius is a straight line; equal end points draw nothing.
    static func arc(from p0: (x: Double, y: Double), to p1: (x: Double, y: Double), rx rxIn: Double, ry ryIn: Double,
                    rotationDeg: Double, largeArc: Bool, sweep: Bool) -> [SVGPathSegment] {
        if p0.x == p1.x && p0.y == p1.y { return [] }
        var rx = Swift.abs(rxIn), ry = Swift.abs(ryIn)
        if rx == 0 || ry == 0 { return [.line(x: p1.x, y: p1.y)] }
        let phi = rotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let pieces = max(1, Int((Swift.abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(pieces)
        let t = 4.0 / 3.0 * tan(step / 4)
        var out: [SVGPathSegment] = []
        var a1 = theta1
        func point(_ a: Double) -> (Double, Double) {
            let x = rx * cos(a), y = ry * sin(a)
            return (cosP * x - sinP * y + cx, sinP * x + cosP * y + cy)
        }
        func deriv(_ a: Double) -> (Double, Double) {
            let x = -rx * sin(a), y = ry * cos(a)
            return (cosP * x - sinP * y, sinP * x + cosP * y)
        }
        for i in 0..<pieces {
            let a2 = a1 + step
            let s = point(a1), e = i == pieces - 1 ? (p1.x, p1.y) : point(a2)
            let d1 = deriv(a1), d2 = deriv(a2)
            out.append(.cubic(c1x: s.0 + t * d1.0, c1y: s.1 + t * d1.1,
                              c2x: e.0 - t * d2.0, c2y: e.1 - t * d2.1, x: e.0, y: e.1))
            a1 = a2
        }
        return out
    }

    /// The box the segments' points (control points included) lie in: x, y, width, height. Nil for no points.
    static func bounds(_ segments: [SVGPathSegment]) -> (x: Double, y: Double, w: Double, h: Double)? {
        var xs: [Double] = [], ys: [Double] = []
        for s in segments {
            switch s {
            case .move(let x, let y), .line(let x, let y): xs.append(x); ys.append(y)
            case .cubic(let a, let b, let c, let d, let x, let y): xs += [a, c, x]; ys += [b, d, y]
            case .quad(let a, let b, let x, let y): xs += [a, x]; ys += [b, y]
            case .close: break
            }
        }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    // MARK: - Scanning

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x2C || bytes[i] == 0x0A || bytes[i] == 0x09 || bytes[i] == 0x0D { i += 1 }
        }

        func peekCommand() -> UInt8? {
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            // Letters are commands, except e/E which belong to an exponent inside a number.
            let isLetter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
            return isLetter && b != UInt8(ascii: "e") && b != UInt8(ascii: "E") ? b : nil
        }

        mutating func advance() { i += 1 }

        /// An arc flag: a single 0 or 1, which may run straight into the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "0"): i += 1; return false
            case UInt8(ascii: "1"): i += 1; return true
            default: return nil
            }
        }

        /// A number: sign, digits, one point, optional exponent. Stops at the next sign or second point, which is
        /// how "-18.95-22" and "1.5.5" are two numbers.
        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var digits = 0, seenPoint = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 48 && b <= 57 { digits += 1; i += 1 }
                else if b == 0x2E && !seenPoint { seenPoint = true; i += 1 }
                else { break }
            }
            guard digits > 0 else { i = begin; return nil }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
                var expDigits = 0
                while j < bytes.count, bytes[j] >= 48 && bytes[j] <= 57 { expDigits += 1; j += 1 }
                if expDigits > 0 { i = j }
            }
            return Double(String(decoding: bytes[begin..<i], as: UTF8.self))
        }
    }
}
