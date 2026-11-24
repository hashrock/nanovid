import Testing
import Foundation
@testable import Nanovid

/// 「最近使った項目を開く」に並べる一覧の組み立て。
///
/// 記録そのものは NSDocumentController の標準のものなので、ここではそこから
/// 受け取った一覧をメニュー用に整えるところだけを見る（実物の記録を汚さない）。
struct RecentProjectsTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func 消えたものは外す() {
        let urls = [url("/a/one.nanovid"), url("/a/gone.nanovid"), url("/b/two.nanovid")]
        let visible = RecentProjects.visible(urls, exists: { $0.lastPathComponent != "gone.nanovid" })
        #expect(visible == [url("/a/one.nanovid"), url("/b/two.nanovid")])
    }

    @Test func 新しい順を保ち上限で切る() {
        let urls = (0..<15).map { url("/p/\($0).nanovid") }
        let visible = RecentProjects.visible(urls, exists: { _ in true })
        #expect(visible.count == RecentProjects.limit)
        #expect(visible.first == urls.first)
        #expect(visible.last == urls[RecentProjects.limit - 1])
    }

    @Test func 消えたものは上限に数えない() {
        let urls = (0..<15).map { url("/p/\($0).nanovid") }
        // 先頭の 5 件が消えていても、残りから 10 件並べる。
        let visible = RecentProjects.visible(urls, exists: { Int($0.deletingPathExtension().lastPathComponent)! >= 5 })
        #expect(visible == Array(urls[5..<15]))
    }

    @Test func 同じ書類は一度だけ() {
        let urls = [url("/a/one.nanovid"), url("/a/./one.nanovid"), url("/a/two.nanovid")]
        let visible = RecentProjects.visible(urls, exists: { _ in true })
        #expect(visible.map(\.lastPathComponent) == ["one.nanovid", "two.nanovid"])
    }

    @Test func 空なら空() {
        #expect(RecentProjects.visible([], exists: { _ in true }).isEmpty)
        #expect(RecentProjects.titles(for: []).isEmpty)
    }

    @Test func 名前は拡張子を外す() {
        #expect(RecentProjects.titles(for: [url("/a/旅行.nanovid")]) == ["旅行"])
    }

    @Test func 同じ名前が並ぶときはフォルダ名を添える() {
        let titles = RecentProjects.titles(for: [
            url("/work/2025/demo.nanovid"), url("/work/2026/demo.nanovid"), url("/x/other.nanovid"),
        ])
        #expect(titles == ["demo — 2025", "demo — 2026", "other"])
    }
}
