import Testing
import UndoTurnLedger

@Suite struct HarnessTests {
  @Test func hookTurnsAreRecognisedByTheirAgentName() {
    #expect(Harness(agent: "claude", command: nil) == .claude)
    #expect(Harness(agent: "omp", command: "Fix the build") == .omp)
    #expect(Harness(agent: "aider", command: nil) == nil)
  }

  @Test func runTurnsAreRecognisedByTheExecutableTheyStarted() {
    #expect(Harness(agent: "run", command: "/opt/homebrew/bin/opencode run hello") == .opencode)
    #expect(Harness(agent: "run", command: "cursor-agent -p fix") == .cursor)
    #expect(Harness(agent: "run", command: "pi") == .pi)
    #expect(Harness(agent: "run", command: "make test") == nil)
    #expect(Harness(agent: "run", command: nil) == nil)
  }

  @Test(arguments: Harness.allCases.filter { $0.mark != nil })
  func everyMarkParsesAndItsPointsStayInsideTheViewBox(_ harness: Harness) throws {
    let mark = try #require(harness.mark)
    #expect(mark.paths.count == mark.pathData.count)
    for path in mark.paths {
      for point in endPoints(path) {
        #expect((-0.01...mark.width + 0.01).contains(point.x))
        #expect((-0.01...mark.height + 0.01).contains(point.y))
      }
    }
  }
}

private func endPoints(_ path: SVGPath) -> [SVGPath.Point] {
  path.elements.compactMap { element in
    switch element {
    case .move(let point), .line(let point), .curve(_, _, let point): point
    case .close: nil
    }
  }
}
