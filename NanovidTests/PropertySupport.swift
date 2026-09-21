import Foundation
@testable import Nanovid

// MARK: - 種つき乱数

/// 種から同じ列を再現できる乱数。SplitMix64。
///
/// 落ちた種をそのまま例示テストに固定できるようにするため、
/// システムの乱数ではなく自前で持つ。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func pick<T>(_ options: [T]) -> T {
        options[int(in: 0...(options.count - 1))]
    }

    mutating func chance(_ probability: Double) -> Bool {
        double(in: 0...1) < probability
    }

    /// 端の値を混ぜる。境界は普通に引くと当たらないが、壊れるのはたいてい端。
    mutating func time(upTo limit: Double, grid: Double) -> Double {
        switch int(in: 0...9) {
        case 0: return 0
        case 1: return limit
        case 2: return grid                     // 1 フレーム
        case 3: return limit - grid
        case 4: return (double(in: 0...limit) / grid).rounded() * grid  // フレーム境界ちょうど
        default: return double(in: 0...limit)
        }
    }
}

// MARK: - 縮小

/// 落ちた列から、まだ落ちる最小の列を探す。
///
/// 1 要素ずつ落として試すだけの素朴なもの。列の長さが数十なら十分で、
/// 「30 手のうちこの 2 手で壊れる」まで縮むと原因が読める。
enum Shrink {
    static func minimalFailing<T>(_ items: [T], stillFails: ([T]) -> Bool) -> [T] {
        guard stillFails(items) else { return items }
        var current = items
        var changed = true
        while changed {
            changed = false
            for i in current.indices {
                var candidate = current
                candidate.remove(at: i)
                if stillFails(candidate) {
                    current = candidate
                    changed = true
                    break
                }
            }
        }
        return current
    }
}

// MARK: - プロジェクトの不変条件

/// どんな操作のあとでも成り立っていてほしいこと。
///
/// 破れた項目を文章で返す。空なら健全。
enum ProjectInvariants {

    static func violations(in project: Project) -> [String] {
        var found: [String] = []
        var seenIDs: Set<UUID> = []

        for track in project.tracks {
            let starts = track.clips.map(\.start)
            if starts != starts.sorted() {
                found.append("「\(track.name)」のクリップが start 昇順でない: \(starts)")
            }

            for clip in track.clips {
                let label = "「\(track.name)」の \(clip.name.isEmpty ? "無題" : clip.name)"

                if !seenIDs.insert(clip.id).inserted {
                    found.append("\(label): クリップ ID が重複している")
                }
                if clip.start < -1e-9 {
                    found.append("\(label): start が負 (\(clip.start))")
                }
                if !(clip.duration > 1e-9) {
                    found.append("\(label): duration が 0 以下 (\(clip.duration))")
                }
                if !clip.start.isFinite || !clip.duration.isFinite {
                    found.append("\(label): start/duration が有限でない")
                }

                switch clip.content {
                case .media(let assetID, let sourceStart):
                    guard let asset = project.asset(assetID) else {
                        found.append("\(label): 素材が見つからない")
                        continue
                    }
                    if sourceStart < -1e-9 {
                        found.append("\(label): sourceStart が負 (\(sourceStart))")
                    }
                    if asset.kind != .image, sourceStart > asset.duration + 1e-9 {
                        found.append("\(label): sourceStart が素材の尺を超えている"
                                     + " (\(sourceStart) > \(asset.duration))")
                    }
                    let isAudioOnly = asset.kind == .audio
                    if (track.kind == .audio) != isAudioOnly {
                        found.append("\(label): \(track.kind) トラックに \(asset.kind) の素材が載っている")
                    }
                case .text(let instance):
                    if project.template(instance.templateID) == nil {
                        found.append("\(label): テンプレートが見つからない")
                    }
                    if track.kind == .audio {
                        found.append("\(label): 音声トラックにテキストが載っている")
                    }
                }
            }
        }

        if let range = project.outputRange, range.end < range.start - 1e-9 {
            found.append("書き出す範囲の終了が開始より前 (\(range.start)〜\(range.end))")
        }
        return found
    }
}

// MARK: - 形だけの比較

/// ID を抜いた、位置と中身だけのプロジェクト表現。
///
/// クリップ・素材・テンプレートの UUID は走らせるたびに変わるので、
/// 「2 回流して同じ結果か」を見るには ID を落とした形で比べる必要がある。
enum ProjectShape {

    static func of(_ project: Project) -> [String] {
        // 参照先は ID そのものではなく、並び順の番号で表す。
        var assetIndex: [UUID: Int] = [:]
        for (i, asset) in project.assets.enumerated() { assetIndex[asset.id] = i }
        var templateIndex: [UUID: Int] = [:]
        for (i, template) in project.textTemplates.enumerated() { templateIndex[template.id] = i }

        var lines = [
            "canvas \(project.canvas.width)x\(project.canvas.height)@\(project.canvas.fps)",
            "range " + (project.outputRange.map { "\(round($0.start))〜\(round($0.end))" } ?? "自動"),
        ]
        for (ti, track) in project.tracks.enumerated() {
            lines.append("track \(ti) \(track.kind) \(track.name)"
                         + " hidden=\(track.isHidden) muted=\(track.isMuted) locked=\(track.isLocked)")
            for clip in track.clips {
                let body: String
                switch clip.content {
                case .media(let assetID, let sourceStart):
                    body = "media#\(assetIndex[assetID].map(String.init) ?? "?")@\(round(sourceStart))"
                case .text(let instance):
                    body = "text#\(templateIndex[instance.templateID].map(String.init) ?? "?")"
                            + "(\(instance.props.keys.sorted().joined(separator: ",")))"
                }
                lines.append("  \(round(clip.start))+\(round(clip.duration)) \(body)"
                             + " op\(round(clip.opacity)) vol\(round(clip.volume))"
                             + " fade\(round(clip.fade.inDuration))/\(round(clip.fade.outDuration))"
                             + " scale\(round(clip.transform.scale))")
            }
        }
        return lines
    }

    /// 浮動小数の下位ビットの揺れで差が出ないように丸める。
    private static func round(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
