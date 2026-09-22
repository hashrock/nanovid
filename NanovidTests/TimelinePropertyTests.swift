import Testing
import Foundation
@testable import Nanovid

/// 目盛りの刻み幅。ズームの全域で成り立つこと。
struct TickSpecPropertyTests {

    /// タイムラインで実際に取りうる倍率の範囲。
    private func zoom(seed: Int) -> Double {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0x71C4)
        switch seed % 5 {
        case 0: return 8          // 最小
        case 1: return 600        // 最大
        default: return generator.double(in: 8...600)
        }
    }

    @Test("ラベルは重ならない間隔で出る", arguments: 0..<300)
    func labelsHaveRoomToBreathe(seed: Int) {
        let pps = zoom(seed: seed)
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        // 最後の段まで来ていたら、それ以上広げようがない。
        guard spec.major != TickSpec.table.last!.major else { return }
        #expect(spec.major * pps >= 64,
                "\(pps)px/秒 でラベル間隔が \(spec.major * pps)pt しかない")
    }

    @Test("刻みは等間隔", arguments: 0..<300)
    func ticksAreEvenlySpaced(seed: Int) {
        let spec = TickSpec.forRuler(pixelsPerSecond: zoom(seed: seed))
        var worst = 0.0
        for i in 0..<400 {
            let gap = spec.time(index: i + 1) - spec.time(index: i)
            worst = max(worst, abs(gap - spec.minor))
        }
        #expect(worst < 1e-9, "刻みが \(worst) 秒ぶれている（minor \(spec.minor)）")
    }

    @Test("大目盛りは subdivisions ごとにちょうど来る", arguments: 0..<300)
    func majorsLandOnTheGrid(seed: Int) {
        let spec = TickSpec.forRuler(pixelsPerSecond: zoom(seed: seed))
        for i in 0..<200 {
            let expected = i % spec.subdivisions == 0
            #expect(spec.isMajor(index: i) == expected, "\(i) 本目の扱いが違う")
        }
        // 大目盛りの間隔は major とそろう。
        #expect(abs(spec.time(index: spec.subdivisions) - spec.major) < 1e-9)
    }

    @Test("隣り合うラベルの文字列が重複しない", arguments: 0..<300)
    func neighbouringLabelsDiffer(seed: Int) {
        let spec = TickSpec.forRuler(pixelsPerSecond: zoom(seed: seed))
        var previous: String?
        for i in stride(from: 0, to: 200 * spec.subdivisions, by: spec.subdivisions) {
            let label = Format.rulerLabel(spec.time(index: i), step: spec.major)
            if let previous {
                #expect(label != previous,
                        "\(spec.major) 秒刻みで「\(label)」が続けて出る（\(zoom(seed: seed))px/秒）")
            }
            previous = label
        }
    }

    /// 目盛りのラベルを時刻に戻す。`Format.rulerLabel` の逆。
    /// 末尾の "." 以降はフレーム番号ではなく小数秒なので、timecode とは別に要る。
    private func seconds(ofRulerLabel label: String) -> Double? {
        let parts = label.split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for part in parts.dropLast() {
            guard let v = Double(part) else { return nil }
            total = (total + v) * 60
        }
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        return total + last
    }

    /// 「ズームしたときにタイムラインが均等にならない」への備え。
    /// 2.5 秒のような半端な刻みを表に入れると、ラベルは 0:00 0:03 0:05 0:08 と
    /// 不揃いに見える。文字列が重複していなくても目盛りとしては壊れている。
    @Test("ラベルの表す時刻が等間隔に並ぶ", arguments: 0..<300)
    func labelsAreEvenlySpaced(seed: Int) {
        let spec = TickSpec.forRuler(pixelsPerSecond: zoom(seed: seed))
        var times: [Double] = []
        for i in stride(from: 0, to: 40 * spec.subdivisions, by: spec.subdivisions) {
            let label = Format.rulerLabel(spec.time(index: i), step: spec.major)
            guard let value = seconds(ofRulerLabel: label) else {
                Issue.record("ラベル「\(label)」を時刻に戻せない")
                return
            }
            times.append(value)
        }
        let gaps = (0..<(times.count - 1)).map { times[$0 + 1] - times[$0] }
        let worst = gaps.map { abs($0 - spec.major) }.max() ?? 0
        #expect(worst < 1e-6, """
            \(spec.major) 秒刻みのはずがラベルは \(Set(gaps.map { String(format: "%.3f", $0) }).sorted()) 秒おき
            """)
    }

    @Test("刻み幅は用意した表の中から選ばれる", arguments: 0..<300)
    func specComesFromTheTable(seed: Int) {
        let spec = TickSpec.forRuler(pixelsPerSecond: zoom(seed: seed))
        #expect(TickSpec.table.contains { $0.major == spec.major && $0.subdivisions == spec.subdivisions },
                "表に無い刻み \(spec)")
    }

    @Test("小目盛りを描くのは詰まっていないときだけ", arguments: 0..<300)
    func minorTicksOnlyWhenTheyFit(seed: Int) {
        let pps = zoom(seed: seed)
        let spec = TickSpec.forRuler(pixelsPerSecond: pps)
        #expect(spec.showsMinor == (spec.minor * pps >= 6))
    }
}

/// 座標変換と吸着。
struct TimelineMathPropertyTests {

    private func values(seed: Int) -> (pps: Double, time: Double, scrollX: Double) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5C01)
        return (g.double(in: 8...600), g.double(in: 0...3600), g.double(in: 0...50000))
    }

    @Test("時刻と内容座標は行き来しても変わらない", arguments: 0..<300)
    func contentCoordinatesRoundTrip(seed: Int) {
        let (pps, time, _) = values(seed: seed)
        let back = TimelineScroll.time(atContentX: TimelineScroll.contentX(forTime: time,
                                                                          pixelsPerSecond: pps),
                                       pixelsPerSecond: pps)
        #expect(abs(back - time) < 1e-9, "\(time) 秒が \(back) 秒になった")
    }

    @Test("表示座標もスクロールを挟んで往復する", arguments: 0..<300)
    func viewportCoordinatesRoundTrip(seed: Int) {
        let (pps, time, scrollX) = values(seed: seed)
        let x = TimelineScroll.viewportX(forTime: time, scrollX: scrollX, pixelsPerSecond: pps)
        let back = TimelineScroll.time(atViewportX: x, scrollX: scrollX, pixelsPerSecond: pps)
        #expect(abs(back - time) < 1e-9, "\(time) 秒が \(back) 秒になった")
    }

    @Test("ズームしてもカーソルの下の時刻が動かない", arguments: 0..<300)
    func zoomKeepsTheTimeUnderTheCursor(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x2003)
        let oldPPS = g.double(in: 8...600), newPPS = g.double(in: 8...600)
        let scrollX = g.double(in: 0...20000), anchorX = g.double(in: 0...1200)

        let before = TimelineScroll.time(atViewportX: anchorX, scrollX: scrollX,
                                         pixelsPerSecond: oldPPS)
        let next = TimelineScroll.anchoredScrollX(scrollX: scrollX, anchorX: anchorX,
                                                  oldPPS: oldPPS, newPPS: newPPS)
        let after = TimelineScroll.time(atViewportX: anchorX, scrollX: next, pixelsPerSecond: newPPS)
        // 先頭で頭打ちになったときだけは、軸を保てない代わりに手前を映さない。
        if next == 0 {
            #expect(after >= before - 1e-9)
        } else {
            #expect(abs(after - before) < 1e-6, "\(before) 秒が \(after) 秒へずれた")
        }
    }

    @Test("スクロール位置は範囲に収まり、2 度かけても変わらない", arguments: 0..<300)
    func clampIsIdempotent(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x0C1A)
        let content = g.double(in: 0...50000), viewport = g.double(in: 100...2000)
        let value = g.double(in: -10000...60000)
        let once = TimelineScroll.clamp(value, contentWidth: content, viewportWidth: viewport)
        let twice = TimelineScroll.clamp(once, contentWidth: content, viewportWidth: viewport)
        #expect(once == twice)
        #expect(once >= 0)
        #expect(once <= max(0, content - viewport) + 1e-9)
    }
}

/// ドラッグの吸着。クリップが振動しないことの土台。
struct SnapPropertyTests {

    private struct Setup {
        var pointer: Double
        var grab: Double
        var targets: [Double]
        var threshold: Double
        var frame: Double
    }

    private func setup(seed: Int) -> Setup {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5A9D)
        let frame = [1.0 / 24, 1.0 / 30, 1.0 / 60][g.int(in: 0...2)]
        // 吸着先はクリップの端。アプリでは必ず canvas.snap を通るので、
        // フレーム境界に乗っている。
        return Setup(pointer: g.double(in: 0...60),
                     grab: g.double(in: -5...5),
                     targets: (0..<g.int(in: 0...6)).map { _ in
                         (g.double(in: 0...60) / frame).rounded() * frame
                     },
                     threshold: g.chance(0.3) ? 0 : g.double(in: 0...0.5),
                     frame: frame)
    }

    private func resolve(_ s: Setup, pointer: Double? = nil) -> Double {
        TimelineSnap.resolve(pointerTime: pointer ?? s.pointer, grabOffset: s.grab,
                             targets: s.targets, threshold: s.threshold, frameDuration: s.frame)
    }

    @Test("同じ入力を食わせ直しても動かない", arguments: 0..<400)
    func resolvingIsStable(seed: Int) {
        let s = setup(seed: seed)
        let first = resolve(s)
        // ドラッグ中にビューが動いて測り直したときと同じ状況。
        let again = resolve(s, pointer: first + s.grab)
        #expect(abs(again - first) < 1e-9,
                "\(first) が \(again) へ動いた（掴んだズレ \(s.grab)）")
    }

    @Test("ポインタを進めれば結果も進む", arguments: 0..<400)
    func resolvingIsMonotonic(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0xB00B)
        let s = setup(seed: seed)
        let delta = g.double(in: 0...10)
        #expect(resolve(s, pointer: s.pointer + delta) >= resolve(s) - 1e-9,
                "ポインタを +\(delta) 秒動かしたのに戻った")
    }

    @Test("吸着先が無ければポインタに 1 フレーム以内で追従する", arguments: 0..<400)
    func followsThePointerWithoutTargets(seed: Int) {
        var s = setup(seed: seed)
        s.targets = []
        var g = SeededGenerator(seed: UInt64(seed) &+ 0xF01A)
        let delta = g.double(in: -10...10)
        // 0 より手前で頭打ちになる場合は、追従しないのが正しい。
        guard s.pointer - s.grab > 1, s.pointer + delta - s.grab > 1 else { return }
        let moved = resolve(s, pointer: s.pointer + delta) - resolve(s)
        #expect(abs(moved - delta) <= s.frame + 1e-9,
                "\(delta) 秒動かしたのに \(moved) 秒しか動いていない")
    }

    @Test("結果は 0 より手前へ行かない", arguments: 0..<400)
    func neverGoesBeforeZero(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x0000)
        var s = setup(seed: seed)
        s.grab = g.double(in: 0...80)      // ポインタより先を掴んだ状態
        #expect(resolve(s) >= 0)
    }

    @Test("閾値の中に吸着先があればそこに乗る", arguments: 0..<300)
    func snapsToNearbyTargets(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5A11)
        let frame = 1.0 / 30
        let target = ((g.double(in: 1...50)) / frame).rounded() * frame
        let threshold = g.double(in: 0.05...0.5)
        // 閾値の内側、フレーム何個ぶんか離れたところを指す。
        // 先にフレーム境界へ丸める実装なので、丸めても閾値の内側にいる点を選ぶ。
        let steps = max(0, Int(threshold * 0.8 / frame))
        let desired = target + Double(g.int(in: -steps...steps)) * frame

        let result = TimelineSnap.resolve(pointerTime: desired, grabOffset: 0,
                                          targets: [target], threshold: threshold,
                                          frameDuration: frame)
        #expect(abs(result - target) < 1e-9, "\(desired) が \(target) に吸着しなかった")
    }
}

/// ホイールの振り分け。入力を飲み込まないこと。
struct WheelPropertyTests {

    private struct Input {
        var deltaX: Double
        var deltaY: Double
        var precise: Bool
        var shift: Bool
        var scrollY: Double
        var maxScrollY: Double
    }

    private func input(seed: Int) -> Input {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x3EE1)
        let precise = g.chance(0.5)
        let maxY = g.chance(0.3) ? 0 : g.double(in: 0...600)
        return Input(deltaX: g.chance(0.4) ? g.double(in: -60...60) : 0,
                     deltaY: g.chance(0.85) ? g.double(in: -60...60) : 0,
                     precise: precise,
                     shift: g.chance(0.25),
                     scrollY: g.double(in: 0...maxY),
                     maxScrollY: maxY)
    }

    private func route(_ i: Input) -> (dx: Double, dy: Double) {
        TimelineWheel.route(deltaX: i.deltaX, deltaY: i.deltaY, precise: i.precise,
                            shift: i.shift, scrollY: i.scrollY, maxScrollY: i.maxScrollY)
    }

    @Test("入力があれば必ずどちらかに動く", arguments: 0..<400)
    func noInputIsSwallowed(seed: Int) {
        let i = input(seed: seed)
        guard i.deltaX != 0 || i.deltaY != 0 else { return }
        let d = route(i)
        #expect(abs(d.dx) + abs(d.dy) > 0,
                "入力 (\(i.deltaX), \(i.deltaY)) が消えた（縦の余白 \(i.maxScrollY)）")
    }

    /// 見るのは縦だけの入力（マウスホイールや二本指の縦スワイプ）。
    /// 横の入力が混ざっているときは振り分けをせずそのまま通し、
    /// 行き過ぎぶんは pan 側で切る。
    @Test("縦だけの入力なら、縦に割り当てるぶんは余白を超えない", arguments: 0..<400)
    func verticalNeverExceedsTheRoom(seed: Int) {
        var i = input(seed: seed)
        i.deltaX = 0
        i.shift = false
        let d = route(i)
        let room = d.dy > 0 ? i.maxScrollY - i.scrollY : i.scrollY
        #expect(abs(d.dy) <= max(0, room) + 1e-9,
                "縦に \(d.dy) 割り当てたが余白は \(room) しかない")
    }

    @Test("縦だけの入力は、量を保ったまま縦と横へ分かれる", arguments: 0..<400)
    func verticalInputKeepsItsMagnitude(seed: Int) {
        var i = input(seed: seed)
        i.deltaX = 0
        i.shift = false
        guard i.deltaY != 0 else { return }
        let d = route(i)
        let scale = i.precise ? 1.0 : TimelineWheel.lineHeight
        #expect(abs(abs(d.dx) + abs(d.dy) - abs(i.deltaY) * scale) < 1e-9,
                "入力 \(i.deltaY) が (\(d.dx), \(d.dy)) になった")
        // 向きも変わらない。
        if d.dx != 0 { #expect((d.dx < 0) == (i.deltaY > 0)) }
        if d.dy != 0 { #expect((d.dy < 0) == (i.deltaY > 0)) }
    }

    @Test("⇧ は必ず横だけになる", arguments: 0..<400)
    func shiftAlwaysMeansHorizontal(seed: Int) {
        var i = input(seed: seed)
        i.shift = true
        #expect(route(i).dy == 0)
    }
}

/// タイムコードの表示と読み取り。
struct TimecodePropertyTests {

    @Test("表示したタイムコードは同じ時刻に読み戻せる", arguments: 0..<400)
    func timecodeRoundTrips(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x71C0DE)
        let fps = [24, 30, 60][g.int(in: 0...2)]
        let seconds = g.chance(0.2) ? g.double(in: 0...5) : g.double(in: 0...7200)

        let text = Format.timecode(seconds, fps: fps)
        let parsed = Format.parseTimecode(text, fps: fps)
        let back = try? #require(parsed)
        guard let back else { return }
        // 表示はフレーム単位に丸まるので、1 フレームぶんまでのずれは許す。
        #expect(abs(back - seconds) < 1.0 / Double(fps) + 1e-9,
                "\(seconds) 秒 → 「\(text)」 → \(back) 秒")
    }

    @Test("読み取った時刻を表示し直すと同じ文字列になる", arguments: 0..<400)
    func parsingIsStable(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x5AB1E)
        let fps = [24, 30, 60][g.int(in: 0...2)]
        let text = Format.timecode(g.double(in: 0...7200), fps: fps)
        guard let parsed = Format.parseTimecode(text, fps: fps) else {
            Issue.record("自分で出した「\(text)」が読めない")
            return
        }
        #expect(Format.timecode(parsed, fps: fps) == text)
    }
}
