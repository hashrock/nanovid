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

    @Test("タイムコードを読み戻せる")
    func parsesTimecode() {
        #expect(Format.parseTimecode("00:00.00", fps: 30) == 0)
        #expect(Format.parseTimecode("01:01.00", fps: 30) == 61)
        #expect(Format.parseTimecode("1:01:01.00", fps: 30) == 3661)
        #expect(abs(Format.parseTimecode("00:01.15", fps: 30)! - 1.5) < 1e-9)
        // 区切りが無ければただの秒数。
        #expect(Format.parseTimecode("83", fps: 30) == 83)
        #expect(Format.parseTimecode("12.5", fps: 30) == 12.5)
    }

    @Test("表示したタイムコードは同じ値に戻る",
          arguments: [0.0, 1.5, 61.0, 3661.0, 123.4666666])
    func timecodeRoundTrips(seconds: Double) {
        let text = Format.timecode(seconds, fps: 30)
        let parsed = Format.parseTimecode(text, fps: 30)
        // 表示はフレーム単位に丸まるので、1 フレームぶんまでの差は許す。
        #expect(abs(parsed! - seconds) < 1.0 / 30)
    }

    @Test("読めない入力は nil", arguments: ["", "  ", "abc", "1:2:3:4", "1:2.3.4", "12s", "-5"])
    func rejectsGarbage(text: String) {
        #expect(Format.parseTimecode(text, fps: 30) == nil)
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
            let timeUnderCursor = TimelineScroll.time(atViewportX: anchorX, scrollX: next,
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
        let timeUnderCursor = TimelineScroll.time(atViewportX: 200, scrollX: next, pixelsPerSecond: 8)
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
        #expect(TimelineScroll.time(atViewportX: 100, scrollX: 0, pixelsPerSecond: 0) == 0)
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
        #expect(TimelineScroll.time(atViewportX: 0, scrollX: 160, pixelsPerSecond: 80) == 2)
        #expect(TimelineScroll.time(atViewportX: 80, scrollX: 160, pixelsPerSecond: 80) == 3)
        #expect(TimelineScroll.time(atViewportX: -1000, scrollX: 0, pixelsPerSecond: 80) == 0)
    }
}

/// 内容座標と表示座標の対応。取り違えるとクリップと目盛りがずれる。
struct TimelineCoordinateTests {

    static let cases: [(time: Double, scrollX: Double, pps: Double)] = [
        (0, 0, 80), (2.5, 0, 80), (2.5, 320, 80), (12.75, 1000, 190),
        (0.04, 0, 600), (61.5, 4200, 8),
    ]

    @Test("時刻 → 内容座標 → 時刻 で元に戻る", arguments: cases)
    func contentRoundTrip(c: (time: Double, scrollX: Double, pps: Double)) {
        let x = TimelineScroll.contentX(forTime: c.time, pixelsPerSecond: c.pps)
        let back = TimelineScroll.time(atContentX: x, pixelsPerSecond: c.pps)
        #expect(abs(back - c.time) < 1e-9)
    }

    @Test("時刻 → 表示座標 → 時刻 で元に戻る", arguments: cases)
    func viewportRoundTrip(c: (time: Double, scrollX: Double, pps: Double)) {
        let x = TimelineScroll.viewportX(forTime: c.time, scrollX: c.scrollX, pixelsPerSecond: c.pps)
        let back = TimelineScroll.time(atViewportX: x, scrollX: c.scrollX, pixelsPerSecond: c.pps)
        #expect(abs(back - c.time) < 1e-9)
    }

    @Test("表示座標は内容座標からスクロール量を引いたもの", arguments: cases)
    func viewportIsContentMinusScroll(c: (time: Double, scrollX: Double, pps: Double)) {
        let content = TimelineScroll.contentX(forTime: c.time, pixelsPerSecond: c.pps)
        let viewport = TimelineScroll.viewportX(forTime: c.time, scrollX: c.scrollX,
                                                pixelsPerSecond: c.pps)
        #expect(abs((content - c.scrollX) - viewport) < 1e-9)
    }

    @Test("クリップと目盛りと再生ヘッドが同じ位置に並ぶ")
    func clipRulerAndPlayheadAgree() {
        // 「2.5 秒のクリップの先頭」「目盛りの 2.5 秒」「再生ヘッドの 2.5 秒」は
        // 画面上で同じ x になるべき。ここがずれると見た目が食い違う。
        let pps = 190.0, scrollX = 320.0, t = 2.5
        let clipX = TimelineScroll.contentX(forTime: t, pixelsPerSecond: pps) - scrollX
        let tickX = TimelineScroll.viewportX(forTime: t, scrollX: scrollX, pixelsPerSecond: pps)
        let headX = TimelineScroll.viewportX(forTime: t, scrollX: scrollX, pixelsPerSecond: pps)
        #expect(abs(clipX - tickX) < 1e-9)
        #expect(abs(tickX - headX) < 1e-9)
    }

    @Test("時刻 0 より手前は返さない")
    func neverNegativeTime() {
        #expect(TimelineScroll.time(atContentX: -500, pixelsPerSecond: 80) == 0)
        #expect(TimelineScroll.time(atViewportX: -500, scrollX: 100, pixelsPerSecond: 80) == 0)
    }
}

/// ドラッグ中の吸着と、振動しないことの保証。
struct TimelineSnapTests {

    private let frame = 1.0 / 30

    @Test("閾値の内側なら吸着先へ寄る")
    func snapsToNearbyTarget() {
        let result = TimelineSnap.snap(2.48, targets: [0, 2.5, 7.0],
                                       threshold: 0.05, frameDuration: frame)
        #expect(result == 2.5)
    }

    @Test("いちばん近い吸着先を選ぶ")
    func picksNearest() {
        let result = TimelineSnap.snap(2.51, targets: [2.5, 2.6],
                                       threshold: 0.2, frameDuration: frame)
        #expect(result == 2.5)
    }

    @Test("閾値の外ならフレーム境界へ丸める")
    func fallsBackToFrameGrid() {
        let result = TimelineSnap.snap(2.48, targets: [7.0],
                                       threshold: 0.05, frameDuration: frame)
        // 2.48 秒は 30fps で 74.4 フレーム → 74 フレーム
        #expect(abs(result - 74 * frame) < 1e-9)
        #expect(abs((result / frame).rounded() - result / frame) < 1e-9)
    }

    @Test("吸着先が無くても落ちない")
    func noTargets() {
        let result = TimelineSnap.snap(1.234, targets: [], threshold: 0.1, frameDuration: frame)
        #expect(abs((result / frame) - (result / frame).rounded()) < 1e-9)
    }

    @Test("同じポインタ位置なら何度計算しても同じ結果になる")
    func resolveIsIdempotent() {
        // ドラッグ中に同じ場所でイベントが繰り返し届いても値が動かないこと。
        // ここが崩れるとクリップが左右に振動する。
        let targets = [0.0, 1.0, 4.5]
        var previous: Double?
        for _ in 0..<10 {
            let value = TimelineSnap.resolve(pointerTime: 3.217, grabOffset: 0.4,
                                             targets: targets, threshold: 0.05,
                                             frameDuration: frame)
            if let previous { #expect(value == previous) }
            previous = value
        }
    }

    @Test("結果はクリップの現在位置に依存しない")
    func resolveIgnoresCurrentPosition() {
        // ポインタの時刻と掴んだときのズレだけで決まる。ビューが動いても影響を受けない。
        // 5.0 - 1.2 = 3.8 は 30fps の格子上（114 フレーム）なので丸めの影響を受けない
        let a = TimelineSnap.resolve(pointerTime: 5.0, grabOffset: 1.2,
                                     targets: [], threshold: 0, frameDuration: frame)
        let b = TimelineSnap.resolve(pointerTime: 5.0, grabOffset: 1.2,
                                     targets: [], threshold: 0, frameDuration: frame)
        #expect(a == b)
        #expect(abs(a - 3.8) < 1e-9)
    }

    @Test("掴んだ位置ぶんのズレが保たれる")
    func keepsGrabOffset() {
        // クリップの真ん中(先頭から 1 秒の位置)を掴んで 8 秒の位置へ動かしたら、
        // 先頭は 7 秒になる。
        let start = TimelineSnap.resolve(pointerTime: 8.0, grabOffset: 1.0,
                                         targets: [], threshold: 0, frameDuration: frame)
        #expect(abs(start - 7.0) < 1e-9)
    }

    @Test("時刻 0 より手前へは動かせない")
    func clampsAtZero() {
        let start = TimelineSnap.resolve(pointerTime: 0.2, grabOffset: 1.0,
                                         targets: [], threshold: 0, frameDuration: frame)
        #expect(start == 0)
    }

    @Test("閾値 0 なら吸着しない")
    func zeroThresholdDisablesSnapping() {
        let result = TimelineSnap.snap(2.48, targets: [2.5], threshold: 0, frameDuration: frame)
        #expect(abs(result - 2.4666666) < 1e-4)    // フレーム丸めのみ
    }
}

/// ホイール入力の振り分け。
///
/// 実測した値を使う。マウスのホイールを 1 ノッチ回すと行単位で
/// `scrollingDeltaY = ±3`、トラックパッドは画素単位で ±40 前後になる。
struct TimelineWheelTests {

    /// レーンが数 pt しか余っていない状態。6 分の素材を入れた直後がこれ。
    private let tightY = (scrollY: 0.0, maxScrollY: 12.0)

    @Test("縦に動かしきれないぶんは横に回る")
    func spillsIntoHorizontal() {
        // 1 ノッチ = 3 行 = 120pt。縦は 12pt しか余っていない。
        let d = TimelineWheel.route(deltaX: 0, deltaY: -3, precise: false, shift: false,
                                    scrollY: tightY.scrollY, maxScrollY: tightY.maxScrollY)
        #expect(d.dy == 12)
        #expect(d.dx == 108)
    }

    @Test("縦を使い切ったあとのホイールは全部が横パンになる")
    func panesHorizontallyOnceLanesAreAtTheEnd() {
        let d = TimelineWheel.route(deltaX: 0, deltaY: -3, precise: false, shift: false,
                                    scrollY: 12, maxScrollY: 12)
        #expect(d.dy == 0)
        #expect(d.dx == 120)
    }

    @Test("レーンに余裕があるうちは素直に縦だけ動く")
    func scrollsLanesWhenThereIsRoom() {
        let d = TimelineWheel.route(deltaX: 0, deltaY: -3, precise: false, shift: false,
                                    scrollY: 0, maxScrollY: 400)
        #expect(d.dy == 120)
        #expect(d.dx == 0)
    }

    @Test("逆向きも同じように振り分ける")
    func spillsIntoHorizontalWhenScrollingBack() {
        // 上へ 1 ノッチ。すでに一番上なので縦には使えない。
        let d = TimelineWheel.route(deltaX: 0, deltaY: 3, precise: false, shift: false,
                                    scrollY: 0, maxScrollY: 12)
        #expect(d.dy == 0)
        #expect(d.dx == -120)
    }

    @Test("⇧ は縦の余りに関わらず横パン固定")
    func shiftAlwaysPansHorizontally() {
        // 行単位のイベントは macOS が先に軸を入れ替えて deltaX に載せてくる。
        let swapped = TimelineWheel.route(deltaX: -3, deltaY: 0, precise: false, shift: true,
                                          scrollY: 0, maxScrollY: 400)
        #expect(swapped == (dx: 120, dy: 0))
        // 入れ替わらずに来た場合も横に回す。
        let raw = TimelineWheel.route(deltaX: 0, deltaY: -3, precise: false, shift: true,
                                      scrollY: 0, maxScrollY: 400)
        #expect(raw == (dx: 120, dy: 0))
    }

    @Test("トラックパッドの二本指は縦横そのまま")
    func preciseDeltasPassThrough() {
        let d = TimelineWheel.route(deltaX: -40, deltaY: -10, precise: true, shift: false,
                                    scrollY: 0, maxScrollY: 400)
        #expect(d == (dx: 40, dy: 10))
    }

    @Test("トラックパッドの縦スワイプも余りは横に回る")
    func preciseVerticalSpills() {
        let d = TimelineWheel.route(deltaX: 0, deltaY: -40, precise: true, shift: false,
                                    scrollY: 0, maxScrollY: 12)
        #expect(d == (dx: 28, dy: 12))
    }

    @Test("縦にも横にも動かせない入力は何も返さない")
    func emptyInput() {
        let d = TimelineWheel.route(deltaX: 0, deltaY: 0, precise: false, shift: false,
                                    scrollY: 0, maxScrollY: 0)
        #expect(d == (dx: 0, dy: 0))
    }

    @Test("縦の余りが無いレーンでも 1 ノッチぶん横に動く", arguments: [-3.0, 3.0])
    func neverDeadWhenLanesFit(delta: Double) {
        let d = TimelineWheel.route(deltaX: 0, deltaY: delta, precise: false, shift: false,
                                    scrollY: 0, maxScrollY: 0)
        #expect(abs(d.dx) == 120)
        #expect(d.dy == 0)
    }
}
