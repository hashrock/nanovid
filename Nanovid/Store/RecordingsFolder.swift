import Foundation

/// 録音の保存先として、ユーザーが選んだフォルダを覚えておく。
///
/// 決め打ちの場所（~/Movies など）には置かない。App Review で
/// 「決め打ちの場所を使っている」「その場所の entitlement に見合う機能が無い」と
/// 指摘された（Guideline 2.4.5(i)、0.2.0 (66)）。Sandbox の下で書けるのは、
/// ユーザーが標準の Open/Save パネルで選んだ場所だけになる。
///
/// 選んだフォルダは app-scoped の security-scoped bookmark にして UserDefaults に
/// 置き、アプリを開き直したあとも書けるようにする（files.bookmarks.app-scope）。
/// アクセスはアプリが終わるまで持ち続ける。別のフォルダを選び直したら手放す。
///
/// Sandbox の外（Debug ビルドやテスト）でも同じ経路を通る。アクセス権の出し入れが
/// 空振りするだけ。
final class RecordingsFolder {

    static let shared = RecordingsFolder()

    static let bookmarkKey = "recordingsFolderBookmark"

    private let defaults: UserDefaults
    /// いま使っているフォルダ。
    private var current: URL?
    /// current について startAccessingSecurityScopedResource が通ったか。
    private var isAccessing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 前に選んでもらったフォルダ。覚えていない・解決できないときは nil。
    func saved() -> URL? {
        if let current { return current }
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        guard let resolved = MediaBookmark.resolve(data) else {
            // フォルダが消えた・別の Mac から設定を持ってきたなど。選び直してもらう。
            forget()
            return nil
        }
        use(resolved.url, scoped: resolved.isScoped)
        if resolved.isStale, let fresh = MediaBookmark.make(for: resolved.url) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return resolved.url
    }

    /// パネルで選んでもらったフォルダを覚える。
    ///
    /// パネルで選んだ場所はこのセッションの間はそのまま書ける。次に起動したときの
    /// ために bookmark を作っておく。
    func remember(_ url: URL) {
        if let data = MediaBookmark.make(for: url) {
            defaults.set(data, forKey: Self.bookmarkKey)
        }
        use(url, scoped: true)
    }

    func forget() {
        release()
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    private func use(_ url: URL, scoped: Bool) {
        guard url != current else { return }
        release()
        current = url
        isAccessing = scoped && url.startAccessingSecurityScopedResource()
    }

    private func release() {
        if isAccessing { current?.stopAccessingSecurityScopedResource() }
        current = nil
        isAccessing = false
    }
}
