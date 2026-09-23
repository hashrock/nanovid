import Testing
import Foundation
@testable import Nanovid

/// 素材の bookmark まわり。
///
/// Sandbox の中でアクセス権を取り戻せるかは、テストの置き場（Debug・Sandbox の外）
/// からは確かめられない。ここで見るのは、その手前の「bookmark を作って保存し、
/// 読み戻して、動いた素材を追いかける」ところ。Sandbox の外でも同じ経路を通る。
struct MediaAccessTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// bookmark は中身を見ないので、素材の形式は何でもよい。
    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func asset(at path: String, bookmark: Data? = nil) -> MediaAsset {
        MediaAsset(path: path, displayName: "素材", kind: .video, duration: 1,
                   naturalSize: nil, hasAudio: false, hasVideo: true, bookmark: bookmark)
    }

    // MARK: - 保存と読み込み

    @Test("以前の版のプロジェクト（bookmark が無い）もそのまま読める")
    func decodesProjectsWithoutBookmarks() throws {
        var project = Project.starter()
        project.assets = [asset(at: "clip.mp4")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        var assets = json["assets"] as! [[String: Any]]
        assets[0].removeValue(forKey: "bookmark")
        json["assets"] = assets
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.assets.first?.bookmark == nil)
        #expect(decoded.assets.first?.path == "clip.mp4")
    }

    @Test("保存すると、読める素材には bookmark が入る")
    func saveFillsInBookmarks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("clip.mp4")
        try makeFile(media)

        var project = Project.starter()
        project.assets = [asset(at: media.path)]
        let url = dir.appendingPathComponent("p.nanovid")
        try ProjectIO.save(project, to: url)

        let loaded = try ProjectIO.load(from: url)
        #expect(loaded.assets[0].bookmark != nil)
        // 置き場所はこれまでどおり相対パスで持つ。
        #expect(loaded.assets[0].path == "clip.mp4")
    }

    @Test("読めない素材があっても保存は止まらず、bookmark は作らない")
    func saveSkipsUnreachableMedia() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var project = Project.starter()
        project.assets = [asset(at: dir.appendingPathComponent("gone.mp4").path)]
        let url = dir.appendingPathComponent("p.nanovid")
        try ProjectIO.save(project, to: url)

        #expect(try ProjectIO.load(from: url).assets[0].bookmark == nil)
    }

    @Test("すでにある bookmark は、素材が読めなくても捨てずに持ち越す")
    func saveKeepsExistingBookmarks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Data([1, 2, 3])

        var project = Project.starter()
        project.assets = [asset(at: dir.appendingPathComponent("gone.mp4").path, bookmark: kept)]
        let url = dir.appendingPathComponent("p.nanovid")
        try ProjectIO.save(project, to: url)

        #expect(try ProjectIO.load(from: url).assets[0].bookmark == kept)
    }

    // MARK: - 開くとき

    @Test("素材だけが動いていたら、bookmark で追いかけて path を書き換える")
    func followsMovedMedia() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("a/clip.mp4")
        let moved = dir.appendingPathComponent("b/renamed.mp4")
        try makeFile(original)

        var project = Project.starter()
        project.assets = [asset(at: original.path, bookmark: MediaBookmark.make(for: original))]

        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)

        let access = MediaAccess()
        defer { access.releaseAll() }
        let changed = access.activate(&project, base: nil)

        #expect(changed)
        #expect(project.assets[0].url(relativeTo: nil).resolvingSymlinksInPath()
                == moved.resolvingSymlinksInPath())
    }

    /// フォルダごと複製したとき、元の場所に素材が残っていても隣のものを使う。
    @Test("path で読めるなら、bookmark が別の場所を指していても path を使う")
    func prefersPathOverBookmark() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("old/clip.mp4")
        let copied = dir.appendingPathComponent("new/clip.mp4")
        try makeFile(original)
        try makeFile(copied)

        var project = Project.starter()
        project.assets = [asset(at: "clip.mp4", bookmark: MediaBookmark.make(for: original))]

        let access = MediaAccess()
        defer { access.releaseAll() }
        let changed = access.activate(&project, base: copied.deletingLastPathComponent())

        #expect(!changed)
        #expect(project.assets[0].path == "clip.mp4")
    }

    @Test("解決できない bookmark は無視して、path のまま残す")
    func ignoresBrokenBookmarks() {
        var project = Project.starter()
        project.assets = [asset(at: "clip.mp4", bookmark: Data([0, 1, 2, 3]))]

        let access = MediaAccess()
        let changed = access.activate(&project, base: nil)

        #expect(!changed)
        #expect(project.assets[0].path == "clip.mp4")
    }

    @Test("読めない素材を拾い出す")
    func listsUnreachableMedia() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir.appendingPathComponent("here.mp4"))

        var project = Project.starter()
        let here = asset(at: "here.mp4")
        let gone = asset(at: "gone.mp4")
        project.assets = [here, gone]

        let missing = MediaAccess.unreachable(in: project, base: dir)
        #expect(missing.map(\.id) == [gone.id])
    }
}
