import CoreMedia
import Foundation

/// 区間分割にかける、レイヤーの時間だけの情報。
struct PlannedLayer: Hashable {
    var start: Double
    var duration: Double
    /// 重なり順。小さいほど背面。
    var z: Int

    var end: Double { start + duration }
}

/// 1 区間ぶんの計画。
struct PlannedSegment: Hashable {
    var range: CMTimeRange
    /// その区間に見えるレイヤーの添字。背面から前面の順。
    var layerIndices: [Int]
}

/// タイムラインを「見えるレイヤーの組み合わせが変わらない区間」へ割る。
///
/// AVFoundation には触らない。映像合成の命令列はここが決めた区間で組む。
enum InstructionPlan {

    /// 区間へ割る。返す区間は `[.zero, end]` を隙間なく、長さ 0 なく覆う。
    ///
    /// AVFoundation は命令列が合成の全域を覆っていないと何も描かない。
    /// 隙間のあるタイムラインでプレビューが真っ黒になったのがこれだった。
    static func segments(for layers: [PlannedLayer], end: CMTime) -> [PlannedSegment] {
        guard end > .zero else { return [] }

        let boundaries = self.boundaries(for: layers, end: end)
        // 連続する境界から順に作るので、隙間も長さ 0 も生まれない。
        return (0..<max(0, boundaries.count - 1)).map { i in
            let range = CMTimeRange(start: boundaries[i], end: boundaries[i + 1])
            let mid = (boundaries[i].secondsOrZero + boundaries[i + 1].secondsOrZero) / 2
            let active = layers.indices
                .filter { layers[$0].start <= mid && mid < layers[$0].end }
                .sorted { layers[$0].z < layers[$1].z }
            return PlannedSegment(range: range, layerIndices: active)
        }
    }

    /// 区間の切れ目。狭義単調増加で、先頭は必ず `.zero`、末尾は必ず `end`。
    ///
    /// 境界は先に CMTime へ落としてから重複を除く。Double のまま集めると、
    /// 同じ瞬間でも計算の経路によって下位ビットがずれ（例: 2.1 + 25.0/30 と
    /// 88.0/30）、長さがほぼ 0 の区間ができる。それを飛ばすと命令列に隙間が空く。
    static func boundaries(for layers: [PlannedLayer], end: CMTime) -> [CMTime] {
        guard end > .zero else { return [] }

        var times: [CMTime] = [.zero, end]
        for layer in layers {
            times.append(clamped(layer.start, to: end))
            times.append(clamped(layer.end, to: end))
        }

        var result: [CMTime] = []
        for time in times.sorted(by: <) where result.last != time {
            result.append(time)
        }
        return result
    }

    /// 0 以上 end 以下に収めて CMTime にする。
    static func clamped(_ seconds: Double, to end: CMTime) -> CMTime {
        guard seconds.isFinite else { return end }
        let time = max(0, seconds).cmTime
        return time > end ? end : time
    }
}
