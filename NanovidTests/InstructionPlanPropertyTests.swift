import Testing
import Foundation
import CoreMedia
@testable import Nanovid

// MARK: - 生成

enum PlanGen {

    /// 同じ瞬間を指す時刻を、わざと違う計算の道すじで作る。
    ///
    /// 同じ「フレーム数」でも経路が違うと下位ビットがずれる。実際に見つかった例が
    /// `2.1 + 25.0/30`（2.9333333333333336）と `88.0/30`（2.933333333333333）で、
    /// 差は 4.4e-16。ところが 600 分の 1 秒へ落とすと 1760 と 1759 に分かれる。
    /// Double のまま「ほぼ同じだから」と片方を捨てると、そこに 600 分の 1 秒の
    /// 隙間が空き、AVFoundation は何も描かない（プレビューが真っ黒になる）。
    ///
    /// 偶然の一致を待たずに済むよう、フレーム数は種ごとの小さな束から選ぶ。
    struct Clock {
        private let fps = 30.0
        private let pool: [Int]

        init(using g: inout SeededGenerator) {
            pool = (0..<8).map { _ in g.int(in: 0...600) }
        }

        func time(using g: inout SeededGenerator) -> Double {
            let frames = Double(pool[g.int(in: 0...(pool.count - 1))])
            switch g.int(in: 0...5) {
            case 0: return frames / fps                    // まとめて割る
            case 1: return frames * (1 / fps)              // 逆数を掛ける
            case 2:                                        // 途中で切って足し直す
                let split = Double(g.int(in: 0...Int(max(1, frames))))
                return split / fps + (frames - split) / fps
            case 3:                                        // 秒の端数から積み上げる
                let whole = (frames / fps).rounded(.down)
                return whole + (frames - whole * fps) / fps
            case 4: return g.double(in: 0...20)            // 端数のある時刻
            default: return Double(g.int(in: 0...20))      // 整数秒
            }
        }
    }

    static func layers(count: Int, clock: Clock, using g: inout SeededGenerator) -> [PlannedLayer] {
        (0..<count).map { z in
            let start = clock.time(using: &g)
            // 長さも同じ流儀で作る。0 や負、はみ出すものも混ぜる。
            let duration: Double
            switch g.int(in: 0...9) {
            case 0: duration = 0
            case 1: duration = -clock.time(using: &g)
            case 2: duration = 1000
            default: duration = clock.time(using: &g)
            }
            return PlannedLayer(start: start, duration: duration, z: z)
        }
    }
}

// MARK: - 性質

struct InstructionPlanPropertyTests {

    private func makePlan(seed: Int) -> (layers: [PlannedLayer], end: CMTime, segments: [PlannedSegment]) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x1A5E)
        let clock = PlanGen.Clock(using: &generator)
        let layers = PlanGen.layers(count: generator.int(in: 0...12), clock: clock, using: &generator)
        let end = max(1.0, clock.time(using: &generator)).cmTime
        return (layers, end, InstructionPlan.segments(for: layers, end: end))
    }

    @Test("区間は先頭から末尾までを隙間なく覆う", arguments: PropertyRuns.seeds(400))
    func segmentsTileTheWholeTimeline(seed: Int) {
        let (_, end, segments) = makePlan(seed: seed)
        guard let first = segments.first, let last = segments.last else {
            Issue.record("seed \(seed): 区間がひとつも無い（end \(end.seconds) 秒）")
            return
        }
        #expect(first.range.start == .zero, "seed \(seed): 先頭が 0 から始まっていない")
        #expect(last.range.end == end, "seed \(seed): 末尾が終端に届いていない")

        for (i, segment) in segments.enumerated() {
            #expect(segment.range.duration > .zero,
                    "seed \(seed): \(i) 番目の区間の長さが 0")
            guard i + 1 < segments.count else { continue }
            #expect(segment.range.end == segments[i + 1].range.start,
                    "seed \(seed): \(i) 番目と \(i + 1) 番目のあいだに隙間がある")
        }
    }

    @Test("レイヤーの切れ目は必ず区間の境目になる", arguments: PropertyRuns.seeds(400))
    func everyLayerEdgeIsABoundary(seed: Int) {
        let (layers, end, segments) = makePlan(seed: seed)
        var boundaries = Set(segments.map(\.range.start))
        segments.last.map { boundaries.insert($0.range.end) }

        for (i, layer) in layers.enumerated() {
            for (name, edge) in [("開始", layer.start), ("終了", layer.end)] {
                let clamped = InstructionPlan.clamped(edge, to: end)
                #expect(boundaries.contains(clamped),
                        "seed \(seed): レイヤー \(i) の\(name) \(clamped.seconds) 秒で切れていない")
            }
        }
    }

    @Test("ひとつの区間の中ではレイヤーの構成が変わらない", arguments: PropertyRuns.seeds(400))
    func layersAreConstantWithinASegment(seed: Int) {
        let (layers, _, segments) = makePlan(seed: seed)
        for segment in segments {
            let from = segment.range.start.secondsOrZero
            let to = segment.range.end.secondsOrZero
            // 区間の中を何点か見る。端ちょうどは半開区間なので少し内側へ寄せる。
            for i in 1..<8 {
                let t = from + (to - from) * Double(i) / 8
                guard t > from, t < to else { continue }
                let active = layers.indices
                    .filter { layers[$0].start <= t && t < layers[$0].end }
                    .sorted { layers[$0].z < layers[$1].z }
                #expect(active == segment.layerIndices, """
                    seed \(seed): \(String(format: "%.9f", t)) 秒で構成が違う
                    区間 \(String(format: "%.9f〜%.9f", from, to)) は \(segment.layerIndices)
                    その時刻では \(active)
                    """)
            }
        }
    }

    @Test("重なり順は背面から前面へ並ぶ", arguments: PropertyRuns.seeds(200))
    func layersAreSortedBackToFront(seed: Int) {
        let (layers, _, segments) = makePlan(seed: seed)
        for segment in segments {
            let zs = segment.layerIndices.map { layers[$0].z }
            #expect(zs == zs.sorted(), "seed \(seed): 重なり順が崩れている \(zs)")
        }
    }

    @Test("レイヤーが無くても全域をひとつの区間で覆う", arguments: PropertyRuns.seeds(50))
    func emptyTimelineStillHasOneSegment(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x0E0E)
        let clock = PlanGen.Clock(using: &generator)
        let end = max(1.0, clock.time(using: &generator)).cmTime
        let segments = InstructionPlan.segments(for: [], end: end)
        #expect(segments.count == 1)
        #expect(segments.first?.range.start == .zero)
        #expect(segments.first?.range.end == end)
        #expect(segments.first?.layerIndices.isEmpty == true)
    }

    @Test("尺が無ければ区間も無い")
    func noSegmentsWithoutDuration() {
        var generator = SeededGenerator(seed: 1)
        let clock = PlanGen.Clock(using: &generator)
        let layers = PlanGen.layers(count: 4, clock: clock, using: &generator)
        #expect(InstructionPlan.segments(for: layers, end: .zero).isEmpty)
        #expect(InstructionPlan.segments(for: layers, end: CMTime(seconds: -1, preferredTimescale: 600)).isEmpty)
    }

    // MARK: 見つかったときの実例

    @Test("経路の違いで 4.4e-16 ずれた境界でも隙間を作らない")
    func nearDuplicateEdgesDoNotMakeGaps() {
        // carve.nanovid がプレビューで真っ暗になったときの実例。
        let a = 2.1 + 25.0 / 30      // 2.9333333333333336
        let b = 88.0 / 30            // 2.933333333333333
        #expect(a != b, "そもそも別の値であること")
        #expect(abs(a - b) < 1e-15)

        let layers = [
            PlannedLayer(start: 2.1, duration: 25.0 / 30, z: 0),
            PlannedLayer(start: b, duration: 1.0, z: 1),
        ]
        let end = 10.0.cmTime
        let segments = InstructionPlan.segments(for: layers, end: end)

        #expect(segments.first?.range.start == .zero)
        #expect(segments.last?.range.end == end)
        for (i, segment) in segments.enumerated() {
            #expect(segment.range.duration > .zero, "\(i) 番目の長さが 0")
            guard i + 1 < segments.count else { continue }
            #expect(segment.range.end == segments[i + 1].range.start, "\(i) 番目の後ろに隙間")
        }
    }
}

/// 生成器そのものの健全性。
struct InstructionPlanGeneratorTests {

    @Test("下位ビットだけ違う時刻が実際に作られている")
    func generatesNearDuplicateEdges() {
        var pairs = 0
        for seed in 0..<400 {
            var generator = SeededGenerator(seed: UInt64(seed) &+ 0x1A5E)
            let clock = PlanGen.Clock(using: &generator)
            let layers = PlanGen.layers(count: generator.int(in: 0...12),
                                        clock: clock, using: &generator)
            let edges = layers.flatMap { [$0.start, $0.end] }.filter { $0.isFinite }
            for a in edges {
                for b in edges where a != b && abs(a - b) < 1e-12 {
                    // 値はほぼ同じなのに、600 分の 1 秒へ落とすと別のところに乗る組。
                    if a.cmTime != b.cmTime { pairs += 1 }
                }
            }
        }
        #expect(pairs > 0, """
            経路違いで下位ビットがずれた時刻が一度も作られていません。
            これが出ないと、真っ暗バグの再発を見張れません。
            """)
    }
}
