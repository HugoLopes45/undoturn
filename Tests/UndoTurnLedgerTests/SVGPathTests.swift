import Testing
import UndoTurnLedger

@Suite struct SVGPathTests {
  @Test func linesAndClosesResolveToAbsolutePointsAndAMoveAfterCloseStartsFromTheSubpath() throws {
    let path = try #require(SVGPath("M1 1h16.5v11H12z m5.5 5.5V12"))

    #expect(
      path.elements == [
        .move(point(1, 1)), .line(point(17.5, 1)), .line(point(17.5, 12)), .line(point(12, 12)),
        .close, .move(point(6.5, 6.5)), .line(point(6.5, 12)),
      ])
  }

  @Test func compactNumbersSplitAtSignsAndSecondDotsAndExtraPairsAfterAMoveAreLines() throws {
    let absolute = try #require(SVGPath("M.5.5-1-1 1e1 0l1,1"))
    let relative = try #require(SVGPath("m1 1 2 2"))

    #expect(
      absolute.elements == [
        .move(point(0.5, 0.5)), .line(point(-1, -1)), .line(point(10, 0)), .line(point(11, 1)),
      ])
    #expect(relative.elements == [.move(point(1, 1)), .line(point(3, 3))])
  }

  @Test func arcFlagsWrittenWithoutSeparatorsFollowTheSweepDirection() throws {
    let clockwise = try #require(SVGPath("M2 2a1 1 0 012 0"))
    let counterclockwise = try #require(SVGPath("M2 2a1 1 0 002 0"))

    #expect(curveEnds(clockwise).count == 2)
    #expect(isClose(curveEnds(clockwise)[0], point(3, 1)))
    #expect(isClose(curveEnds(clockwise)[1], point(4, 2)))
    #expect(isClose(curveEnds(counterclockwise)[0], point(3, 3)))
  }

  @Test func arcRadiiTooSmallForTheEndpointsGrowToReachThem() throws {
    let path = try #require(SVGPath("M0 0A.1 .1 0 0 1 2 0"))

    #expect(curveEnds(path).count == 2)
    #expect(isClose(curveEnds(path)[0], point(1, -1)))
    #expect(isClose(curveEnds(path)[1], point(2, 0)))
  }

  @Test func smoothCubicsReflectThePreviousControlPointOrStartAtTheCurrentPoint() throws {
    let reflected = try #require(SVGPath("M0 0C0 1 1 1 1 0S2-1 2 0"))
    let unreflected = try #require(SVGPath("M0 0S1 1 2 0"))

    #expect(reflected.elements.last == .curve(point(1, -1), point(2, -1), point(2, 0)))
    #expect(unreflected.elements.last == .curve(point(0, 0), point(1, 1), point(2, 0)))
  }

  @Test func quadraticsBecomeCubicsAndSmoothQuadraticsReflectTheirControlPoint() throws {
    let path = try #require(SVGPath("M0 0Q1.5 1.5 3 0T6 0"))

    #expect(
      path.elements == [
        .move(point(0, 0)), .curve(point(1, 1), point(2, 1), point(3, 0)),
        .curve(point(4, -1), point(5, -1), point(6, 0)),
      ])
  }

  @Test(arguments: ["", "  ", "L1 1", "M0", "M1 1 X", "M1 1z 2 2", "M1 1a1 1 0 21 1 1", "M1 1e"])
  func rejectsMalformedPathData(_ data: String) {
    #expect(SVGPath(data) == nil)
  }
}

private func point(_ x: Double, _ y: Double) -> SVGPath.Point {
  SVGPath.Point(x, y)
}

private func curveEnds(_ path: SVGPath) -> [SVGPath.Point] {
  path.elements.compactMap { element in
    guard case .curve(_, _, let end) = element else { return nil }
    return end
  }
}

private func isClose(_ left: SVGPath.Point, _ right: SVGPath.Point) -> Bool {
  abs(left.x - right.x) < 1e-9 && abs(left.y - right.y) < 1e-9
}
