import Foundation

/// タイムラインの音の大きさ。短い窓ごとの RMS（線形、0…1）を並べたもの。
struct AudioLevels: Sendable {
    /// 最初の窓が始まる時刻（秒）。
    var origin: Double = 0
    /// 窓ひとつの長さ（秒）。
    var window: Double
    var rms: [Float]
}

/// 喋っていない区間（無音）を見つける。音の大きさの列だけを見る計算で、読み込みは挟まない。
///
/// 収録した話し声から間を抜いて詰める、いわゆるジャンプカットに使う。
/// 抜くのは EditorStore.extract(ranges:) で、全トラックから同じ時間だけ抜くので
/// 映像・声・テロップのあわせはずれない。
enum SilenceDetection {

    struct Options: Hashable, Sendable {
        /// これより小さい音を無音とみなす（dBFS）。
        var thresholdDB: Double = -40
        /// これより短い無音は、息継ぎや話の間として残す。
        var minimumSilence: Double = 0.5
        /// 声の頭と尻が欠けないよう、無音の両端に残す長さ。
        var padding: Double = 0.15

        /// 長い間だけを抜く。
        static let gentle = Options(minimumSilence: 1.0, padding: 0.25)
        static let standard = Options()
        /// 短い間も抜いて、テンポよく詰める。
        static let tight = Options(minimumSilence: 0.3, padding: 0.08)
    }

    /// 無音の区間を時刻の昇順で返す。
    ///
    /// 両端に `padding` ぶんの余白を残す。ただしタイムラインの頭と尻の無音は
    /// 声に接していないので、余白を残さずまるごと返す。
    static func silentRanges(in levels: AudioLevels, options: Options) -> [ClosedRange<Double>] {
        let threshold = Float(pow(10, options.thresholdDB / 20))
        let count = levels.rms.count
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?

        // 末尾に番兵を置いて、最後まで続いた無音も同じ道で閉じる。
        for i in 0...count {
            if i < count, levels.rms[i] < threshold {
                if runStart == nil { runStart = i }
                continue
            }
            guard let start = runStart else { continue }
            runStart = nil
            guard Double(i - start) * levels.window >= options.minimumSilence - 1e-9 else { continue }

            let lead = start == 0 ? 0 : options.padding
            let trail = i == count ? 0 : options.padding
            let lower = levels.origin + Double(start) * levels.window + lead
            let upper = levels.origin + Double(i) * levels.window - trail
            if upper - lower > 1e-6 { ranges.append(lower...upper) }
        }
        return ranges
    }

    /// 実際に抜く範囲。フレーム境界にそろえ、書き出す範囲の外には手を出さない。
    /// そろえた結果くっついたものはひとつにまとめる（重なったまま抜くと二重に詰まる）。
    static func cuts(in levels: AudioLevels, options: Options, project: Project) -> [ClosedRange<Double>] {
        silentRanges(in: levels, options: options)
            .compactMap { range -> ClosedRange<Double>? in
                let lower = project.canvas.snap(max(range.lowerBound, project.outputStart))
                let upper = project.canvas.snap(min(range.upperBound, project.outputEnd))
                return upper - lower > 1e-6 ? lower...upper : nil
            }
            .merged()
    }
}
