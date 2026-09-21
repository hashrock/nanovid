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
