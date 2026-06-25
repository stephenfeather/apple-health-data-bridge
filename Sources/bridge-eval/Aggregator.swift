import Foundation

/// PURE aggregator (design §7). Groups per-case scores by (fixture, model) and computes mean ± stdev
/// F1 across the N samples, catastrophic rate, and output-consistency (mean pairwise Jaccard agreement
/// of per-sample hit loinc-sets). Population stdev (so n=1 -> stdev 0.0, n carried for the Report's
/// "single sample" note — Fix 3). Platform-free.
enum Aggregator {
    static func aggregate(_ scores: [CaseScore], promptHashes: [String]) -> RunResults {
        let groups = Dictionary(grouping: scores, by: { Pair(fixture: $0.fixture, model: $0.model) })
        let stats = groups.keys.sorted().map { key -> FixtureModelStats in
            let group = groups[key]!.sorted { $0.sample < $1.sample }
            let strict = aggregateF1(group.map { $0.strict.f1 })
            let lenient = aggregateF1(group.map { $0.lenient.f1 })
            let catRate = Double(group.filter { $0.catastrophic }.count) / Double(group.count)
            let consistency = outputConsistency(group)
            return FixtureModelStats(fixture: key.fixture, model: key.model,
                                     strictF1: strict, lenientF1: lenient,
                                     outputConsistency: consistency, catastrophicRate: catRate)
        }
        return RunResults(promptHashes: promptHashes, stats: stats)
    }

    private struct Pair: Hashable, Comparable {
        let fixture: String
        let model: String
        static func < (lhs: Pair, rhs: Pair) -> Bool {
            lhs.fixture == rhs.fixture ? lhs.model < rhs.model : lhs.fixture < rhs.fixture
        }
    }

    private static func aggregateF1(_ values: [Double]) -> AggregateF1 {
        guard !values.isEmpty else { return AggregateF1(mean: 0, stdev: 0, n: 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return AggregateF1(mean: mean, stdev: variance.squareRoot(), n: values.count)
    }

    private static func hitSet(_ score: CaseScore) -> Set<String> {
        Set(score.matches.filter { $0.outcome == .hit }.map { $0.loinc })
    }

    private static func outputConsistency(_ group: [CaseScore]) -> Double {
        guard group.count > 1 else { return 1.0 }
        let sets = group.map(hitSet)
        var total = 0.0
        var pairs = 0
        for i in 0..<sets.count {
            for j in (i + 1)..<sets.count {
                let union = sets[i].union(sets[j])
                let agreement = union.isEmpty ? 1.0 : Double(sets[i].intersection(sets[j]).count) / Double(union.count)
                total += agreement
                pairs += 1
            }
        }
        return pairs == 0 ? 1.0 : total / Double(pairs)
    }
}
