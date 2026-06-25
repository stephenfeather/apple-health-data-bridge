import XCTest
@testable import bridge_eval

final class AggregatorTests: XCTestCase {
    private func score(fixture: String, model: String, sample: Int, f1: Double,
                       catastrophic: Bool = false, hitLoincs: [String] = []) -> CaseScore {
        CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: catastrophic,
                  strict: F1(precision: f1, recall: f1, f1: f1),
                  lenient: F1(precision: f1, recall: f1, f1: f1),
                  skipHistogram: [:],
                  matches: hitLoincs.map { MatchRecord(loinc: $0, outcome: .hit, fieldErrors: nil) },
                  patient: PatientCorrectness(distinctCountCorrect: true, identityCorrect: true))
    }

    func testEmptyProducesNoStats() {
        let r = Aggregator.aggregate([], promptHashes: ["abc"])
        XCTAssertEqual(r.promptHashes, ["abc"])
        XCTAssertTrue(r.stats.isEmpty)
    }

    func testMeanAndStdevAcrossSamples() {
        let scores = [
            score(fixture: "f", model: "m", sample: 0, f1: 0.6),
            score(fixture: "f", model: "m", sample: 1, f1: 0.8),
            score(fixture: "f", model: "m", sample: 2, f1: 1.0),
        ]
        let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
        XCTAssertEqual(r.stats.count, 1)
        let s = r.stats[0]
        XCTAssertEqual(s.strictF1.n, 3)
        XCTAssertEqual(s.strictF1.mean, 0.8, accuracy: 1e-9)
        // population stdev of [0.6,0.8,1.0] = sqrt((0.04+0+0.04)/3) ≈ 0.163299
        XCTAssertEqual(s.strictF1.stdev, 0.16329931618, accuracy: 1e-6)
    }

    func testSingleSampleStdevIsZeroWithNOne() {
        // Default --samples 1: population stdev is 0.0 with n=1 (intentional; not a divide bug). Report
        // surfaces n=1 as "single sample" rather than "no variance" (Fix 3).
        let r = Aggregator.aggregate([score(fixture: "f", model: "m", sample: 0, f1: 0.7)],
                                     promptHashes: ["abc"])
        XCTAssertEqual(r.stats[0].strictF1.n, 1)
        XCTAssertEqual(r.stats[0].strictF1.stdev, 0.0)
        XCTAssertEqual(r.stats[0].strictF1.mean, 0.7, accuracy: 1e-9)
    }

    func testCatastrophicRate() {
        let scores = [
            score(fixture: "f", model: "m", sample: 0, f1: 0, catastrophic: true),
            score(fixture: "f", model: "m", sample: 1, f1: 1.0),
        ]
        let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
        XCTAssertEqual(r.stats[0].catastrophicRate, 0.5, accuracy: 1e-9)
    }

    func testOutputConsistencyIdenticalSamplesIsOne() {
        let scores = [
            score(fixture: "f", model: "m", sample: 0, f1: 1, hitLoincs: ["8867-4", "718-7"]),
            score(fixture: "f", model: "m", sample: 1, f1: 1, hitLoincs: ["718-7", "8867-4"]),
        ]
        let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
        XCTAssertEqual(r.stats[0].outputConsistency, 1.0, accuracy: 1e-9)
    }

    func testGroupsByFixtureAndModel() {
        let scores = [
            score(fixture: "f1", model: "m1", sample: 0, f1: 1),
            score(fixture: "f1", model: "m2", sample: 0, f1: 0.5),
        ]
        let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
        XCTAssertEqual(r.stats.count, 2)
        XCTAssertEqual(r.stats.map { $0.model }, ["m1", "m2"])
    }
}
