import Testing
import Foundation
@testable import Nanovid

/// タイムライン目盛りの刻み幅。
/// 「大目盛りが 2.5 秒になってラベルが 0:02, 0:02 と重複する」という不具合の再発防止。
struct TimelineTicksTests {

    /// アプリのズームスライダーが取り得る範囲。
    static let zoomRange: [Double] = stride(from: 12.0, through: 400.0, by: 4.0).map { $0 }

    @Test("大目盛りはきりのいい値から選ばれる", arguments: zoomRange)
    func majorIsFromNiceTable(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        #expect(TickSpec.table.contains { $0.major == spec.major })
    }

    @Test("ラベルが詰まらない間隔が確保される", arguments: zoomRange)
    func labelSpacingIsEnough(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps, minLabelSpacing: 64)
        #expect(spec.major * pps >= 64)
    }

    @Test("必要以上に粗くならない", arguments: zoomRange)
    func majorIsSmallestThatFits(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps, minLabelSpacing: 64)
        // ひとつ小さいきりのいい値では間隔が足りないこと（＝最小の候補が選ばれている）
        let smaller = TickSpec.table.last { $0.major < spec.major }
        if let smaller {
            #expect(smaller.major * pps < 64)
        }
    }

    @Test("小目盛りは大目盛りを整数等分する", arguments: zoomRange)
    func minorDividesMajorEvenly(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        #expect(spec.subdivisions >= 1)
        let recomposed = spec.minor * Double(spec.subdivisions)
        #expect(abs(recomposed - spec.major) < 1e-9)
    }

    @Test("小目盛りは狭すぎるときに省かれる", arguments: zoomRange)
    func minorTicksAreHiddenWhenTooTight(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps, minMinorSpacing: 6)
        if spec.showsMinor {
            #expect(spec.minor * pps >= 6)
        } else {
            #expect(spec.minor * pps < 6)
        }
    }

    @Test("大目盛りは等間隔に並ぶ", arguments: zoomRange)
    func majorTicksAreEvenlySpaced(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        let times = (0..<16).map { spec.time(index: $0 * spec.subdivisions) }
        for i in 1..<times.count {
            #expect(abs((times[i] - times[i - 1]) - spec.major) < 1e-9)
        }
    }

    @Test("ラベルが重複しない", arguments: zoomRange)
    func labelsAreDistinct(pps: Double) {
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        let labels = (0..<16).map { i -> String in
            Format.rulerLabel(spec.time(index: i * spec.subdivisions), step: spec.major)
        }
        #expect(Set(labels).count == labels.count, "重複したラベル: \(labels)")
    }

    @Test("大目盛りの判定は分割数どおり")
    func majorIndexing() {
        let spec = TickSpec(major: 1, subdivisions: 4, showsMinor: true)
        #expect(spec.isMajor(index: 0))
        #expect(!spec.isMajor(index: 1))
        #expect(!spec.isMajor(index: 3))
        #expect(spec.isMajor(index: 4))
        #expect(abs(spec.time(index: 4) - 1.0) < 1e-12)
        #expect(abs(spec.time(index: 2) - 0.5) < 1e-12)
    }

    @Test("ズームを上げても刻みが粗くならない")
    func stepIsMonotonicInZoom() {
        var previous = Double.greatestFiniteMagnitude
        for pps in stride(from: 12.0, through: 400.0, by: 2.0) {
            let major = TickSpec.forRuler(pixelsPerSecond: pps).major
            #expect(major <= previous)
            previous = major
        }
    }

    @Test("幅を埋めるだけの本数を返す")
    func minorCountCoversWidth() {
        let spec = TickSpec(major: 1, subdivisions: 4, showsMinor: true)   // minor = 0.25
        // 幅 800pt, 80pt/秒 → 10 秒 → 小目盛り 40 本ぶん。端まで描けるよう余分に 1 本。
        #expect(spec.minorCount(width: 800, pixelsPerSecond: 80) == 41)
    }

    @Test("ゼロ除算しない")
    func handlesZeroZoom() {
        let spec = TickSpec.forRuler(pixelsPerSecond: 0)
        #expect(spec.major > 0)
        #expect(spec.minorCount(width: 100, pixelsPerSecond: 0) == 0)
    }
}

struct RulerLabelTests {

    @Test("1 秒以上の刻みでは秒までを出す")
    func wholeSeconds() {
        #expect(Format.rulerLabel(0, step: 1) == "0:00")
        #expect(Format.rulerLabel(65, step: 5) == "1:05")
        #expect(Format.rulerLabel(120, step: 60) == "2:00")
        #expect(Format.rulerLabel(3665, step: 60) == "1:01:05")
    }

    @Test("1 秒未満の刻みでは小数を出す")
    func subSecond() {
        #expect(Format.rulerLabel(2.5, step: 0.5) == "0:02.5")
        #expect(Format.rulerLabel(0.25, step: 0.25) == "0:00.25")
        #expect(Format.rulerLabel(1.0, step: 0.5) == "0:01.0")
        #expect(Format.rulerLabel(61.5, step: 0.5) == "1:01.5")
    }

    @Test("刻み幅から必要な桁数が決まる")
    func digits() {
        #expect(Format.fractionDigits(forStep: 1) == 0)
        #expect(Format.fractionDigits(forStep: 5) == 0)
        #expect(Format.fractionDigits(forStep: 0.5) == 1)
        #expect(Format.fractionDigits(forStep: 0.1) == 1)
        #expect(Format.fractionDigits(forStep: 0.25) == 2)
        #expect(Format.fractionDigits(forStep: 0.05) == 2)
    }

    @Test("タイムコードはフレーム単位まで出す")
    func timecode() {
        #expect(Format.timecode(0, fps: 30) == "00:00.00")
        #expect(Format.timecode(1.5, fps: 30) == "00:01.15")
        #expect(Format.timecode(61.0, fps: 30) == "01:01.00")
        #expect(Format.timecode(3661.0, fps: 30) == "1:01:01.00")
    }
}
