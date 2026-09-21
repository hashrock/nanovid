import Foundation

/// 範囲を決めて抜き、時間を詰める操作（切り抜き）。
///
/// 「開始を打つ → 再生ヘッドを動かす → 切り抜く」の流れ。
/// 全トラックから同じ時間だけ抜くので、ナレーションと映像のあわせがずれない。
extension EditorStore {

    /// 再生ヘッドの位置を切り抜きの開始点にする。
    func markExtractStart() {
        extractStart = project.canvas.snap(currentTime)
    }

    func cancelExtract() {
        extractStart = nil
    }

    /// 印から再生ヘッドまでの範囲。打っていなければ nil。
    /// 開始より手前にヘッドを戻しても、向きをそろえて返す。
    var pendingExtractRange: ClosedRange<Double>? {
        guard let start = extractStart else { return nil }
        let head = project.canvas.snap(currentTime)
        return min(start, head)...max(start, head)
    }

    /// 印から再生ヘッドまでを抜いて詰める。
    func extractMarkedRange() {
        guard let range = pendingExtractRange else { return }
        extractStart = nil
        guard range.upperBound - range.lowerBound > 1e-6 else { return }
        extract(range: range)
        seek(to: range.lowerBound)
    }

    /// 指定した範囲を全トラックから抜き、後ろを詰める。
    func extract(range: ClosedRange<Double>) {
        let length = range.upperBound - range.lowerBound
        guard length > 1e-6 else { return }
        edit { p in
            for ti in p.tracks.indices where !p.tracks[ti].isLocked {
                let cut = p.tracks[ti].clips.flatMap { Self.cut($0, by: range, length: length) }
                p.tracks[ti].clips = cut.sorted { $0.start < $1.start }
            }
        }
        selectedClipIDs = []
    }

    /// 1 つのクリップを範囲で切る。
    /// 範囲にまたがるものは、かかった部分だけを捨てて前後をつなぐ。
    static func cut(_ clip: Clip, by range: ClosedRange<Double>, length: Double) -> [Clip] {
        let epsilon = 1e-9

        // 範囲より手前。そのまま。
        if clip.end <= range.lowerBound + epsilon { return [clip] }

        // 範囲より後ろ。抜いたぶん前へ詰める。
        if clip.start >= range.upperBound - epsilon {
            var moved = clip
            moved.start -= length
            return [moved]
        }

        var pieces: [Clip] = []

        // 頭が範囲の手前に残っている。
        if clip.start < range.lowerBound - epsilon {
            var head = clip
            head.duration = range.lowerBound - clip.start
            head.fade.outDuration = 0
            pieces.append(head)
        }

        // 尻が範囲の後ろに残っている。詰めた結果、範囲の先頭に来る。
        if clip.end > range.upperBound + epsilon {
            var tail = clip
            tail.id = UUID()
            tail.start = range.lowerBound
            tail.duration = clip.end - range.upperBound
            tail.fade.inDuration = 0
            if case .media(let assetID, let sourceStart) = clip.content {
                // 抜いたぶんだけ素材の中も進める。
                tail.content = .media(assetID: assetID,
                                      sourceStart: sourceStart + (range.upperBound - clip.start))
            }
            pieces.append(tail)
        }

        // どちらも残らなければ、まるごと範囲の中だったということ。
        return pieces
    }
}
