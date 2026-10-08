import Testing
import Foundation
@testable import Nanovid

/// 録音の保存先（RecordingsFolder）。
///
/// 決め打ちの場所（~/Movies など）には置かず、ユーザーが選んだフォルダだけを
/// 覚えておく（App Review 2.4.5(i)）。Sandbox の中でアクセス権を取り戻せるかは
/// テストの置き場（Debug・Sandbox の外）からは確かめられないので、ここで見るのは
/// 「覚えて、読み戻して、壊れていたら捨てる」ところ。
struct RecordingsFolderTests {

    /// 本物の設定を汚さないよう、テストごとに別の UserDefaults を使う。
    private func makeDefaults() throws -> UserDefaults {
        let name = "nanovid-recordings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("選んでいなければ保存先は無い（決め打ちの場所に逃がさない）")
    func noPresetLocation() throws {
        #expect(RecordingsFolder(defaults: try makeDefaults()).saved() == nil)
    }

    @Test("選んだフォルダは、アプリを開き直しても bookmark から戻る")
    func remembersAcrossLaunches() throws {
        let defaults = try makeDefaults()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        RecordingsFolder(defaults: defaults).remember(dir)
        #expect(defaults.data(forKey: RecordingsFolder.bookmarkKey) != nil)

        // 開き直した体で、別のインスタンスから読む。
        let restored = try #require(RecordingsFolder(defaults: defaults).saved())
        #expect(restored.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
    }

    @Test("解決できない bookmark は捨てて、選び直してもらう")
    func forgetsBrokenBookmark() throws {
        let defaults = try makeDefaults()
        defaults.set(Data([0, 1, 2, 3]), forKey: RecordingsFolder.bookmarkKey)
        #expect(RecordingsFolder(defaults: defaults).saved() == nil)
        #expect(defaults.data(forKey: RecordingsFolder.bookmarkKey) == nil)
    }
}
