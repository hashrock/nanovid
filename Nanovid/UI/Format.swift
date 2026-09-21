import Foundation

enum Format {
    /// 00:12.15 形式（分:秒.フレーム）。1 時間を超えたら時も出す。
    static func timecode(_ seconds: Double, fps: Int) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let frames = Int(((total - Double(whole)) * Double(fps)).rounded(.down))
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, frames)
            : String(format: "%02d:%02d.%02d", m, s, frames)
    }

    /// 目盛り用の短い表記。step が 1 秒未満のときは小数を出す。
    /// 秒に丸めてしまうと、刻みが細かいときにラベルが重複してしまうため。
    static func rulerLabel(_ seconds: Double, step: Double) -> String {
        let decimals = fractionDigits(forStep: step)
        let whole = Int(seconds)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60

        if decimals == 0 {
            let rounded = Int(seconds.rounded())
            let rh = rounded / 3600, rm = (rounded % 3600) / 60, rs = rounded % 60
            return rh > 0 ? String(format: "%d:%02d:%02d", rh, rm, rs)
                          : String(format: "%d:%02d", rm, rs)
        }

        let fraction = seconds - Double(whole)
        let fractionText = String(format: "%.\(decimals)f", fraction).dropFirst()  // 先頭の "0" を落とす
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) + fractionText
                     : String(format: "%d:%02d", m, s) + fractionText
    }

    /// 刻み幅に必要な小数桁数。0.5 なら 1 桁、0.25 なら 2 桁。
    static func fractionDigits(forStep step: Double) -> Int {
        guard step < 1 else { return 0 }
        if abs((step * 10).rounded() - step * 10) < 1e-9 { return 1 }
        if abs((step * 100).rounded() - step * 100) < 1e-9 { return 2 }
        return 3
    }

    /// 尺の表示用。2.4 なら "2.4"、3.0 なら "3"。
    static func seconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        let m = whole / 60, s = whole % 60
        return String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
