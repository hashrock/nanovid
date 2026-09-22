import AppKit
import SwiftUI

/// パネルの仕切り。ドラッグで隣のパネルの大きさを変える。
///
/// SwiftUI の `VSplitView` / `HSplitView` は入れ子にすると外側のつまみが
/// 効かなくなるので使わない。自前で持てば入れ子の制約も無くなる。
enum PaneDivider {

    static let thickness: CGFloat = 7

    /// 縦に伸びる仕切り。左右パネルの幅を変える。
    struct Vertical: View {
        @Binding var width: CGFloat
        let range: ClosedRange<CGFloat>
        /// 右側のパネルを動かすときは true（ドラッグ方向が反転する）。
        var trailing: Bool = false

        @State private var startWidth: CGFloat?

        var body: some View {
            ZStack {
                Color.clear
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .frame(width: PaneDivider.thickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            // 画面全体の座標で測る。仕切り自身がドラッグで動くので、
            // 既定のローカル空間だと移動量が縮んでついてこない。
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        let delta = Double(value.translation.width) * (trailing ? -1 : 1)
                        width = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
        }
    }

    /// 横に伸びる仕切り。下段の高さを変える。
    struct Horizontal: View {
        @Binding var bottomHeight: CGFloat
        let range: ClosedRange<CGFloat>

        @State private var startHeight: CGFloat?

        var body: some View {
            ZStack {
                Color.clear
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
            .frame(height: PaneDivider.thickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            // 画面全体の座標で測る。仕切り自身がドラッグで動くので、
            // 既定のローカル空間だと移動量が縮んでついてこない。
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startHeight ?? bottomHeight
                        if startHeight == nil { startHeight = bottomHeight }
                        // 下へドラッグ＝下段が縮む
                        let next = base - Double(value.translation.height)
                        bottomHeight = min(max(next, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startHeight = nil }
            )
        }
    }
}

/// 画面下段の切り替え。切り貼りと字幕打ちは行き来が多いので、
/// モーダルにせず同じ場所でタブにする（字幕を打ちながらプレビューを見たい）。
enum BottomTab: String, CaseIterable, Identifiable {
    case timeline, text
    var id: String { rawValue }
    var label: String { self == .timeline ? L("タイムライン") : L("字幕") }
}

/// 下段の見出しに置くタブ切り替え。タイムライン側と字幕側で同じものを使う。
struct BottomTabPicker: View {
    @Binding var selection: BottomTab

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(BottomTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
