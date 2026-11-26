import XCTest
@testable import Strand

/// The body map's path reader: relative and absolute commands, numbers run together, smooth curves, and every path
/// of the shipped geometry.
final class SVGPathDataTests: XCTestCase {

    func testAbsoluteAndRelativeLinesAndClose() {
        XCTAssertEqual(SVGPathData.parse("M10 20L30 40l5 5H100v-10z"),
                       [.move(x: 10, y: 20), .line(x: 30, y: 40), .line(x: 35, y: 45), .line(x: 100, y: 45),
                        .line(x: 100, y: 35), .close])
    }

    func testNumbersRunTogetherAtTheirSigns() {
        XCTAssertEqual(SVGPathData.parse("M272.91 422.84c-18.95-17.19-22-57-12.64-78.79"),
                       [.move(x: 272.91, y: 422.84),
                        .cubic(c1x: 272.91 - 18.95, c1y: 422.84 - 17.19, c2x: 272.91 - 22, c2y: 422.84 - 57,
                               x: 272.91 - 12.64, y: 422.84 - 78.79)])
    }

    func testASecondPointEndsANumberAndAnExponentIsRead() {
        XCTAssertEqual(SVGPathData.parse("M.5.5L1e1 -2E-1"), [.move(x: 0.5, y: 0.5), .line(x: 10, y: -0.2)])
    }

    func testImplicitRepeatsAfterAMoveAreLines() {
        XCTAssertEqual(SVGPathData.parse("m1 1 2 2 3 3"), [.move(x: 1, y: 1), .line(x: 3, y: 3), .line(x: 6, y: 6)])
    }

    func testImplicitRepeatsOfACurve() {
        let out = SVGPathData.parse("M0 0c1 1 2 2 3 3 1 1 2 2 3 3")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2], .cubic(c1x: 4, c1y: 4, c2x: 5, c2y: 5, x: 6, y: 6))
    }

    func testASmoothCurveMirrorsTheLastControlPoint() {
        let out = SVGPathData.parse("M0 0C0 10 10 10 10 0S20 -10 20 0")
        XCTAssertEqual(out[2], .cubic(c1x: 10, c1y: -10, c2x: 20, c2y: -10, x: 20, y: 0), "(2 * 10 - 10, 2 * 0 - 10)")
        let none = SVGPathData.parse("M5 5S9 9 10 10")
        XCTAssertEqual(none[1], .cubic(c1x: 5, c1y: 5, c2x: 9, c2y: 9, x: 10, y: 10), "no previous curve: the current point")
    }

    func testASmoothQuadraticMirrorsToo() {
        let out = SVGPathData.parse("M0 0Q5 10 10 0T20 0")
        XCTAssertEqual(out[2], .quad(cx: 15, cy: -10, x: 20, y: 0))
    }

    func testAnArcStopsTheReadInsteadOfGuessing() {
        XCTAssertEqual(SVGPathData.parse("M0 0L1 1A5 5 0 0 1 9 9L2 2"), [.move(x: 0, y: 0), .line(x: 1, y: 1)])
    }

    func testGarbageAndEmptyReadAsNothingWithoutCrashing() {
        XCTAssertEqual(SVGPathData.parse(""), [])
        XCTAssertEqual(SVGPathData.parse("12 34"), [])
        XCTAssertEqual(SVGPathData.parse("M"), [])
        XCTAssertEqual(SVGPathData.parse("Mx y"), [])
    }

    func testBounds() throws {
        let b = try XCTUnwrap(SVGPathData.bounds(SVGPathData.parse("M10 20L30 60z")))
        XCTAssertEqual([b.x, b.y, b.w, b.h], [10, 20, 20, 40])
        XCTAssertNil(SVGPathData.bounds([]))
    }

    // MARK: - The shipped geometry

    private struct View: Decodable {
        var viewBox: [Double]
        var regions: [String: [String]]
        var silhouette: [String]
        var blend: [String: [String]]
    }

    func testEveryShippedPathReadsAndStaysInsideItsView() throws {
        // Found by walking up from this file, so it does not depend on where the tests are compiled from.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var url = dir.appendingPathComponent("Strand/Resources/BodyGeometry.json")
        while !FileManager.default.fileExists(atPath: url.path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            url = dir.appendingPathComponent("Strand/Resources/BodyGeometry.json")
        }
        let bodies = try JSONDecoder().decode([String: [String: View]].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(bodies.keys), ["male", "female"])
        var count = 0
        for (body, sides) in bodies {
            XCTAssertEqual(Set(sides.keys), ["front", "back"])
            for (side, view) in sides {
                let vb = view.viewBox
                XCTAssertEqual(vb.count, 4)
                for d in view.silhouette + view.regions.values.flatMap({ $0 }) {
                    let segments = SVGPathData.parse(d)
                    XCTAssertFalse(segments.isEmpty, "\(body)/\(side) unreadable: \(d.prefix(40))")
                    XCTAssertEqual(segments.first, segments.first.flatMap { if case .move = $0 { return $0 } else { return nil } },
                                   "\(body)/\(side) does not start with a move")
                    let box = try XCTUnwrap(SVGPathData.bounds(segments))
                    XCTAssertTrue(box.x >= vb[0] - 40 && box.y >= vb[1] - 40
                                  && box.x + box.w <= vb[0] + vb[2] + 40 && box.y + box.h <= vb[1] + vb[3] + 40,
                                  "\(body)/\(side) leaves its view: \(box)")
                    count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 300, "210 muscle paths and the silhouettes")
    }
}
