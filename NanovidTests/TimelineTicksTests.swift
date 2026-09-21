import Testing
import Foundation
import SwiftUI
@testable import Nanovid

/// タイムライン目盛りの刻み幅。
/// 「大目盛りが 2.5 秒になってラベルが 0:02, 0:02 と重複する」という不具合の再発防止。
struct TimelineTicksTests {

    /// アプリのズームが取り得る範囲（TimelineView.minZoom ... maxZoom）。
    static let zoomRange: [Double] = stride(from: TimelineView.minZoom,
                                            through: TimelineView.maxZoom, by: 6.0).map { $0 }

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
        for pps in stride(from: TimelineView.minZoom, through: TimelineView.maxZoom, by: 2.0) {
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

/// ズームとスクロール位置の関係。
struct TimelineScrollTests {

    @Test("ズームしてもカーソル位置の時刻が動かない")
    func zoomKeepsTimeUnderCursor() {
        // スクロール 400pt、80px/秒 → 画面左端は 5 秒。カーソルは左端から 200pt（＝7.5 秒）。
        let scrollX = 400.0, anchorX = 200.0, oldPPS = 80.0
        // 7.5 秒を左端から 200pt の位置に置ける倍率のみ（＝7.5 * pps >= 200）。
        for newPPS in [80.0, 200.0, 600.0] {
            let next = TimelineScroll.anchoredScrollX(scrollX: scrollX, anchorX: anchorX,
                                                      oldPPS: oldPPS, newPPS: newPPS)
            let timeUnderCursor = TimelineScroll.time(atX: anchorX, scrollX: next,
                                                      pixelsPerSecond: newPPS)
            #expect(abs(timeUnderCursor - 7.5) < 1e-9, "\(newPPS)px/秒 でずれた")
        }
    }

    @Test("時刻 0 より手前は出せないので、そこで頭打ちになる")
    func clampsAtTimelineStart() {
        // 7.5 秒 × 8px/秒 = 60pt しかないので、カーソル位置(200pt)には置けない。
        let next = TimelineScroll.anchoredScrollX(scrollX: 400, anchorX: 200,
                                                  oldPPS: 80, newPPS: 8)
        #expect(next == 0)
        let timeUnderCursor = TimelineScroll.time(atX: 200, scrollX: next, pixelsPerSecond: 8)
        // 軸は保てないが、先頭より手前を映すことはない
        #expect(timeUnderCursor > 7.5)
    }

    @Test("先頭付近でズームアウトしても負のスクロールにならない")
    func doesNotScrollBeforeZero() {
        for newPPS in stride(from: 8.0, through: 600.0, by: 8.0) {
            let next = TimelineScroll.anchoredScrollX(scrollX: 0, anchorX: 100,
                                                      oldPPS: 400, newPPS: newPPS)
            #expect(next >= 0)
        }
    }

    @Test("ズーム率が同じならスクロール位置も変わらない")
    func noChangeWhenZoomIsSame() {
        let next = TimelineScroll.anchoredScrollX(scrollX: 321, anchorX: 55,
                                                  oldPPS: 80, newPPS: 80)
        #expect(abs(next - 321) < 1e-9)
    }

    @Test("ゼロ除算しない")
    func handlesZeroZoom() {
        #expect(TimelineScroll.anchoredScrollX(scrollX: 10, anchorX: 5,
                                               oldPPS: 0, newPPS: 80) == 10)
        #expect(TimelineScroll.time(atX: 100, scrollX: 0, pixelsPerSecond: 0) == 0)
    }

    @Test("スクロール位置は内容の範囲に収まる")
    func clampsToContent() {
        #expect(TimelineScroll.clamp(-50, contentWidth: 1000, viewportWidth: 400) == 0)
        #expect(TimelineScroll.clamp(9999, contentWidth: 1000, viewportWidth: 400) == 600)
        #expect(TimelineScroll.clamp(300, contentWidth: 1000, viewportWidth: 400) == 300)
        // 内容がビューポートより狭ければ動かない
        #expect(TimelineScroll.clamp(120, contentWidth: 300, viewportWidth: 400) == 0)
    }

    @Test("画面位置から時刻へ変換できる")
    func timeAtX() {
        #expect(TimelineScroll.time(atX: 0, scrollX: 160, pixelsPerSecond: 80) == 2)
        #expect(TimelineScroll.time(atX: 80, scrollX: 160, pixelsPerSecond: 80) == 3)
        #expect(TimelineScroll.time(atX: -1000, scrollX: 0, pixelsPerSecond: 80) == 0)
    }
}
