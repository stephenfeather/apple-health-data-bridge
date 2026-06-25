import XCTest
@testable import bridge_eval

final class ReportCommandTests: XCTestCase {
    func testRenderTableHasHeaderAndRow() {
        let results = RunResults(promptHashes: ["abc123"], stats: [
            FixtureModelStats(fixture: "vitals-basic", model: "claude-opus-4-8",
                              strictF1: AggregateF1(mean: 0.8, stdev: 0.1, n: 3),
                              lenientF1: AggregateF1(mean: 0.9, stdev: 0.05, n: 3),
                              outputConsistency: 0.66, catastrophicRate: 0.0)])
        let table = Report.renderTable(results)
        XCTAssertTrue(table.contains("fixture"))
        XCTAssertTrue(table.contains("vitals-basic"))
        XCTAssertTrue(table.contains("claude-opus-4-8"))
        XCTAssertTrue(table.contains("0.80"))   // strict mean, 2dp
    }

    func testRenderTableSingleSampleAnnotatesN1() {
        let results = RunResults(promptHashes: ["abc"], stats: [
            FixtureModelStats(fixture: "f", model: "m",
                              strictF1: AggregateF1(mean: 0.7, stdev: 0.0, n: 1),
                              lenientF1: AggregateF1(mean: 0.7, stdev: 0.0, n: 1),
                              outputConsistency: 1.0, catastrophicRate: 0.0)])
        let table = Report.renderTable(results)
        XCTAssertTrue(table.contains("n=1 (single sample)"))
        XCTAssertFalse(table.contains("0.70±0.00"))   // must NOT render a misleading ±0.00
    }

    func testRenderTableEmpty() {
        let table = Report.renderTable(RunResults(promptHashes: ["x"], stats: []))
        XCTAssertTrue(table.contains("no results"))
    }

    func testReadScoresRoundTrip() throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-report-\(UUID().uuidString)")
        let score = Scorer.catastrophic(fixture: "f", model: "m", sample: 0)
        try ArtifactWriter.writeScored(score, key: "f__m__0", runDir: runDir)
        let scores = try ArtifactReader.readScores(runDir: runDir)
        XCTAssertEqual(scores.count, 1)
        XCTAssertTrue(scores.first?.catastrophic ?? false)
    }
}
