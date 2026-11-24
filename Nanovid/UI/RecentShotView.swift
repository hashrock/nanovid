#if DEBUG
import SwiftUI

/// スクリーンショット用（デバッグビルドだけ）。メニューは本物のクリックなしには
/// 開けないので、「ファイル > 最近使った項目を開く」の中身を窓の中に縦に並べる。
///
///   Nanovid --shot-recents <書類>...
///
/// 渡した書類を「新しい順の記録」と見なし、メニューと同じ手順（RecentProjects の
/// visible / titles）で並べる。実物の記録は読まない・書かない。見つからずに
/// 外したものも、外したことがわかるよう下に添える。
struct RecentShotView: View {
    let recorded: [URL]

    static var requestedURLs: [URL]? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--shot-recents") else { return nil }
        return args[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        let visible = RecentProjects.visible(recorded) { FileManager.default.fileExists(atPath: $0.path) }
        let titles = RecentProjects.titles(for: visible)
        let dropped = recorded.filter { url in !visible.contains(url) }

        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "ファイル > 最近使った項目を開く")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(zip(visible, titles)), id: \.0) { url, title in
                    row(title)
                }
                if !visible.isEmpty {
                    Divider().padding(.vertical, 5)
                }
                row("メニューを消去", enabled: !visible.isEmpty)
            }
            .padding(5)
            .frame(width: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            if !dropped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "見つからないので一覧から外したもの（撮影用の注記）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(dropped, id: \.self) { url in
                        Text(verbatim: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
                            .font(.caption.monospaced())
                            .strikethrough()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, enabled: Bool = true) -> some View {
        Text(LocalizedStringKey(title))
            .foregroundStyle(enabled ? .primary : .tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
