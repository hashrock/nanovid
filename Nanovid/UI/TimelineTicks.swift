import Foundation

/// タイムライン目盛りの刻み幅。
///
/// 大目盛り（ラベル付き）は必ず「きりのいい時間」から選び、小目盛りはそれを
/// 整数で割ったものにする。こうしないと 2.5 秒ごとのラベルのような半端な間隔や、
/// 丸めによる重複表示が起きる。
struct TickSpec: Equatable {
    /// ラベルを出す間隔（秒）。
    let major: Double
    /// 大目盛りを何等分するか。
    let subdivisions: Int
    /// 小目盛りを描くかどうか。狭すぎるときは省く。
    let showsMinor: Bool

    var minor: Double { major / Double(subdivisions) }

    /// きりのいい大目盛りと、その自然な分割数の組。
    static let table: [(major: Double, subdivisions: Int)] = [
        (0.1, 5),      // 0.02
        (0.25, 5),     // 0.05
        (0.5, 5),      // 0.1
        (1, 4),        // 0.25
        (2, 4),        // 0.5
        (5, 5),        // 1
        (10, 5),       // 2
        (15, 3),       // 5
        (30, 6),       // 5
        (60, 6),       // 10
        (120, 4),      // 30
        (300, 5),      // 60
        (600, 10),     // 60
        (900, 3),      // 300
        (1800, 6),     // 300
        (3600, 6),     // 600
    ]

    /// 1 秒あたりの表示幅から刻み幅を決める。
    /// - Parameters:
    ///   - minLabelSpacing: ラベル同士が詰まらないための最小間隔(pt)。
    ///   - minMinorSpacing: 小目盛りを描く最小間隔(pt)。
    static func forRuler(pixelsPerSecond pps: Double,
                         minLabelSpacing: Double = 64,
                         minMinorSpacing: Double = 6) -> TickSpec {
        guard pps > 0 else {
            return TickSpec(major: 3600, subdivisions: 6, showsMinor: false)
        }
        let entry = table.first { $0.major * pps >= minLabelSpacing } ?? table[table.count - 1]
        let minor = entry.major / Double(entry.subdivisions)
        return TickSpec(major: entry.major,
                        subdivisions: entry.subdivisions,
                        showsMinor: minor * pps >= minMinorSpacing)
    }

    /// 幅 width(pt) を埋めるのに必要な小目盛りの本数。
    func minorCount(width: Double, pixelsPerSecond pps: Double) -> Int {
        guard pps > 0, minor > 0 else { return 0 }
        return Int((width / (minor * pps)).rounded(.up)) + 1
    }

    /// i 本目の小目盛りが大目盛りかどうか。
    func isMajor(index i: Int) -> Bool { i % subdivisions == 0 }

    /// i 本目の小目盛りの時刻。浮動小数の誤差が積もらないよう掛け算で出す。
    func time(index i: Int) -> Double { Double(i) * minor }
}

/// タイムラインの座標変換。UI から切り離してテストできるようにしてある。
///
/// 扱う座標系は 2 つだけ。取り違えないよう、変換は必ずここを通す。
///
/// - **内容座標 (content)**: タイムラインの中身そのもの。`x = 時刻 × pixelsPerSecond`。
///   クリップのレイアウトとドロップ位置はこちら。スクロールしても値は変わらない。
/// - **表示座標 (viewport)**: レーン表示領域の左上を原点とした画面上の位置。
///   `x = 内容座標 − scrollX`。目盛り・再生ヘッド・ポインタ位置はこちら。
enum TimelineScroll {

    // MARK: - 時刻と座標の変換

    static func contentX(forTime time: Double, pixelsPerSecond: Double) -> Double {
        time * pixelsPerSecond
    }

    static func viewportX(forTime time: Double, scrollX: Double, pixelsPerSecond: Double) -> Double {
        contentX(forTime: time, pixelsPerSecond: pixelsPerSecond) - scrollX
    }

    static func time(atContentX x: Double, pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return max(0, x / pixelsPerSecond)
    }

    static func time(atViewportX x: Double, scrollX: Double, pixelsPerSecond: Double) -> Double {
        time(atContentX: x + scrollX, pixelsPerSecond: pixelsPerSecond)
    }

    /// ズームしても、画面上 anchorX の位置に見えている時刻が動かないスクロール位置を返す。
    /// - Parameters:
    ///   - scrollX: いまのスクロール位置(pt)。
    ///   - anchorX: 基準にする画面上の横位置(pt)。カーソル位置やビューポート中央。
    static func anchoredScrollX(scrollX: Double, anchorX: Double,
                                oldPPS: Double, newPPS: Double) -> Double {
        guard oldPPS > 0, newPPS > 0 else { return scrollX }
        let anchorTime = (scrollX + anchorX) / oldPPS
        return max(0, anchorTime * newPPS - anchorX)
    }

    /// スクロール位置を内容の範囲に収める。
    static func clamp(_ value: Double, contentWidth: Double, viewportWidth: Double) -> Double {
        let maxScroll = max(0, contentWidth - viewportWidth)
        return min(max(0, value), maxScroll)
    }

}

/// ドラッグ中の吸着。
enum TimelineSnap {

    /// desired に最も近い吸着先を返す。閾値内に無ければフレーム境界へ丸める。
    static func snap(_ desired: Double, targets: [Double],
                     threshold: Double, frameDuration: Double) -> Double {
        if threshold > 0,
           let near = targets.min(by: { abs($0 - desired) < abs($1 - desired) }),
           abs(near - desired) < threshold {
            return near
        }
        guard frameDuration > 0 else { return desired }
        return (desired / frameDuration).rounded() * frameDuration
    }

    /// ドラッグ中の目標時刻。
    ///
    /// ポインタの「時刻」と掴んだ瞬間のズレだけで決まるので、
    /// ドラッグの途中でクリップが動いても結果が変わらない。
    /// ビューの現在位置からの相対移動量で計算すると、
    /// 「ビューが動く → 測り直す → また動く」で振動する。
    static func resolve(pointerTime: Double, grabOffset: Double,
                        targets: [Double], threshold: Double,
                        frameDuration: Double) -> Double {
        let desired = pointerTime - grabOffset
        return max(0, snap(desired, targets: targets,
                           threshold: threshold, frameDuration: frameDuration))
    }
}
