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

    /// timecode の逆。"01:23.15" / "1:01:23.15" / "83.5" / "83" を秒へ。
    /// ":" を含むときは最後の "." 以降をフレーム番号として扱い、
    /// 含まないときは素直に小数秒として読む。
    /// 数字と区切り以外が混ざっていたら nil を返す（入力途中の文字列を弾くため）。
    static func parseTimecode(_ text: String, fps: Int) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) else {
            return nil
        }

        // ":" が無ければただの秒数。"12.5" は 12.5 秒。
        guard trimmed.contains(":") else {
            return Double(trimmed).map { max(0, $0) }
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, let last = parts.last else { return nil }

        // 手前の要素は時と分。
        var total = 0.0
        for part in parts.dropLast() {
            guard let v = Int(part.isEmpty ? "0" : String(part)) else { return nil }
            total = (total + Double(v)) * 60
        }

        // 末尾は "秒" か "秒.フレーム"。
        let secondsAndFrames = last.split(separator: ".", omittingEmptySubsequences: false)
        guard secondsAndFrames.count <= 2,
              let seconds = Int(secondsAndFrames[0].isEmpty ? "0" : String(secondsAndFrames[0]))
        else { return nil }
        total += Double(seconds)

        if secondsAndFrames.count == 2 {
            guard let frames = Int(secondsAndFrames[1].isEmpty ? "0" : String(secondsAndFrames[1]))
            else { return nil }
            total += Double(frames) / Double(max(1, fps))
        }
        return max(0, total)
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
