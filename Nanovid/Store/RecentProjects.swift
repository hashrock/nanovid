import AppKit
import Foundation
import Observation

/// 「ファイル > 最近使った項目を開く」に並べるプロジェクト。
///
/// 記録は `NSDocumentController` の標準の「最近使った項目」をそのまま使う。
/// 端末ローカルにしか残らない（iCloud では同期しない）ので、自前の保存先は持たない。
/// Dock のアイコンの右クリックに出る一覧とも同じものになる。
///
/// nanovid は NSDocument を使わないので、標準の「最近使った項目を開く」メニューは
/// 出てこない。記録だけは開く・別名で保存のたびにしてあったので、その一覧を
/// メニューに出す役をここが受け持つ。SwiftUI のメニューは観測できる値でしか
/// 描き直されないため、一覧を写して持つ。メインスレッドだけで触る（EditorStore と同じ）。
@Observable
final class RecentProjects {

    static let shared = RecentProjects()

    /// メニューに並べる上限。システム設定の「最近使った項目」の数がこれより小さければそちらに従う。
    static let limit = 10

    /// 開ける（いまもその場所にある）ものだけ、新しい順に。
    private(set) var urls: [URL] = []

    @ObservationIgnored private let controller: NSDocumentController
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private var activation: NSObjectProtocol?

    init(controller: NSDocumentController = .shared,
         fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.controller = controller
        self.fileExists = fileExists
        refresh()
        // アプリを離れているあいだに Finder で消したり動かしたりしたものを、戻ったときに外す。
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 開いた・保存した書類を一覧の先頭へ。
    func note(_ url: URL) {
        controller.noteNewRecentDocumentURL(url)
        refresh()
    }

    /// 「メニューを消去」。確認はしない（標準のメニューと同じ）。
    func clear() {
        controller.clearRecentDocuments(nil)
        refresh()
    }

    func refresh() {
        let next = Self.visible(controller.recentDocumentURLs, exists: fileExists)
        if next != urls { urls = next }
    }

    /// 消えた・動かしたものを外し、同じ書類の重複をまとめ、上限で切る。
    static func visible(_ urls: [URL], exists: (URL) -> Bool, limit: Int = limit) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where result.count < limit {
            let key = url.standardizedFileURL.path
            guard exists(url), seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// メニューに出す名前。名前が同じものが並ぶときは、置き場所のフォルダ名を添える。
    static func titles(for urls: [URL]) -> [String] {
        let names = urls.map { $0.deletingPathExtension().lastPathComponent }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return zip(urls, names).map { url, name in
            guard counts[name, default: 0] > 1 else { return name }
            return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
        }
    }
}

extension EditorStore {
    /// 「最近使った項目を開く」から選んだとき。
    func openRecent(_ url: URL) {
        // 選んだあとで消された・動かされたときは、一覧から外して知らせる。
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentProjects.shared.refresh()
            presentError(L("開けませんでした"), L("「\(url.lastPathComponent)」が見つかりません。移動したか削除された可能性があります。"))
            return
        }
        guard documentURL?.standardizedFileURL.path != url.standardizedFileURL.path,
              confirmDiscardIfNeeded() else { return }
        open(url: url)
    }
}
