import AppKit
import Foundation

/// 素材ファイルへのアクセス権を、プロジェクトを開き直したあとまで持ち越す仕組み。
///
/// App Sandbox の下では、ユーザーが開いた .nanovid そのものにしか触れない。隣に
/// 置いた素材も読めない。そこで取り込んだ時点で素材ごとに security-scoped bookmark
/// を作ってプロジェクトに保存しておき、開くときにそれを解決してアクセス権を取り戻す。
///
/// bookmark は app-scoped（このアプリ・このユーザーのものだけ解決できる）。
/// document-scoped にしなかったのは、保存が atomic な書き換えでファイルが
/// 差し替わるのと、未保存のプロジェクトに取り込んだ時点では持ち主の書類が
/// まだ無いため。別の Mac に持っていったときなど解決できない場合は、素材の
/// フォルダを選んでもらって作り直す（EditorStore.locateMissingMedia）。
///
/// Sandbox の外（Debug ビルドやテスト）でも同じ経路を通る。そのときはアクセス権の
/// 出し入れが空振りするだけで、bookmark は素材が動いたときの追跡に効く。
enum MediaBookmark {

    /// 取り込んだ素材の bookmark を作る。作れなければ nil（path だけで探す）。
    static func make(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        // Sandbox の外では security scope 付きを作れないことがある。移動の追跡には
        // 普通の bookmark で足りるので、そちらで置いておく。
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    struct Resolved {
        var url: URL
        /// security scope 付きで解決できたか。できたときは start / stop の対象。
        var isScoped: Bool
        /// 作り直した方がよい（素材が動いた・OS が古いと判断した）。
        var isStale: Bool
    }

    static func resolve(_ data: Data) -> Resolved? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return Resolved(url: url, isScoped: true, isStale: stale)
        }
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return Resolved(url: url, isScoped: false, isStale: stale)
        }
        return nil
    }
}

/// いま開いているプロジェクトの素材について、取り戻したアクセス権を持っておく。
/// 別のプロジェクトに切り替えるときに手放す。
final class MediaAccess {

    static let shared = MediaAccess()

    private var accessing: [URL] = []

    /// 開いたプロジェクトの素材について、bookmark からアクセス権を取り戻す。
    ///
    /// 置き場所の優先は path（プロジェクトからの相対パス）。フォルダごと移動・
    /// 複製したときに、元の場所ではなく隣の素材を使ってほしいため。path で読めない
    /// ときだけ bookmark の指す先へ path を書き換える（素材だけが動いた場合）。
    ///
    /// - Returns: path か bookmark を書き換えたか。保存し直す必要があるかの目安。
    @discardableResult
    func activate(_ project: inout Project, base: URL?) -> Bool {
        releaseAll()
        var changed = false
        for i in project.assets.indices {
            guard let data = project.assets[i].bookmark,
                  let resolved = MediaBookmark.resolve(data) else { continue }
            if resolved.isScoped, resolved.url.startAccessingSecurityScopedResource() {
                accessing.append(resolved.url)
            }
            let byPath = project.assets[i].url(relativeTo: base)
            if !Self.isReachable(byPath), Self.isReachable(resolved.url) {
                project.assets[i].path = resolved.url.path
                changed = true
            }
            if resolved.isStale, let fresh = MediaBookmark.make(for: resolved.url) {
                project.assets[i].bookmark = fresh
                changed = true
            }
        }
        return changed
    }

    func releaseAll() {
        for url in accessing { url.stopAccessingSecurityScopedResource() }
        accessing = []
    }

    /// 読めない素材。Sandbox で権限が無いものも、ファイルが消えたものも含む。
    static func unreachable(in project: Project, base: URL?) -> [MediaAsset] {
        project.assets.filter { !isReachable($0.url(relativeTo: base)) }
    }

    /// 実際に開けるか。
    ///
    /// FileManager.isReadableFile（access(2)）は POSIX の権限しか見ず、Sandbox に
    /// 拒まれるファイルでも true を返す。Sandbox の下で確かめたら、案内が出ずに
    /// AVFoundation の「アクセス権がない」エラーだけが出た。開いてすぐ閉じる。
    static func isReachable(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
