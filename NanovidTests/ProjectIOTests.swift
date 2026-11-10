import Testing
import Foundation
@testable import Nanovid

struct ProjectIOTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("保存して読み込むと内容が一致する")
    func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var project = Project.starter()
        project.name = "テスト"
        project.canvas = CanvasSpec(width: 1080, height: 1920, fps: 60)
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 1.5, duration: 2,
                 content: .text(TextInstance(templateID: template.id,
                                             props: ["text": .string("日本語も往復する")])),
                 fade: Fade(inDuration: 0.2, outDuration: 0.3))
        ]

        let url = dir.appendingPathComponent("test.nanovid")
        try ProjectIO.save(project, to: url)
        let loaded = try ProjectIO.load(from: url)

        #expect(loaded.name == project.name)
        #expect(loaded.canvas == project.canvas)
        #expect(loaded.tracks.count == project.tracks.count)
        #expect(loaded.textTemplates.count == project.textTemplates.count)

        let clip = loaded.tracks[1].clips.first
        #expect(clip?.content.textInstance?.props["text"]?.stringValue == "日本語も往復する")
        #expect(clip?.fade.inDuration == 0.2)
        #expect(abs((clip?.start ?? 0) - 1.5) < 1e-9)
    }

    @Test("プロジェクトと同じ階層以下の素材は相対パスで保存される")
    func nearbyAssetsBecomeRelative() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let media = dir.appendingPathComponent("footage/clip.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: media)

        var project = Project.starter()
        project.assets = [MediaAsset(path: media.path, displayName: "clip", kind: .video,
                                     duration: 5, naturalSize: nil, hasAudio: false, hasVideo: true)]

        let url = dir.appendingPathComponent("test.nanovid")
        try ProjectIO.save(project, to: url)
        let loaded = try ProjectIO.load(from: url)

        #expect(loaded.assets[0].path == "footage/clip.mp4")
        // 相対パスから元の場所を引き直せる
        #expect(loaded.assets[0].url(relativeTo: dir).standardizedFileURL
                == media.standardizedFileURL)
    }

    @Test("離れた場所の素材は絶対パスのまま")
    func distantAssetsStayAbsolute() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: other)
        }

        let media = other.appendingPathComponent("clip.mp4")
        try Data().write(to: media)

        var project = Project.starter()
        project.assets = [MediaAsset(path: media.path, displayName: "clip", kind: .video,
                                     duration: 5, naturalSize: nil, hasAudio: false, hasVideo: true)]

        let url = dir.appendingPathComponent("test.nanovid")
        try ProjectIO.save(project, to: url)
        let loaded = try ProjectIO.load(from: url)
        #expect(loaded.assets[0].path.hasPrefix("/"))
    }

    @Test("フォルダごと移動しても開ける")
    func movingTheFolderKeepsAssetsResolvable() throws {
        let dir = try makeTempDir()
        let moved = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: moved)
        }

        let media = dir.appendingPathComponent("clip.mp4")
        try Data().write(to: media)
        var project = Project.starter()
        project.assets = [MediaAsset(path: media.path, displayName: "clip", kind: .video,
                                     duration: 5, naturalSize: nil, hasAudio: false, hasVideo: true)]

        let url = dir.appendingPathComponent("test.nanovid")
        try ProjectIO.save(project, to: url)

        // フォルダごと別の場所へコピーしたことにする
        let movedProject = moved.appendingPathComponent("test.nanovid")
        let movedMedia = moved.appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: url, to: movedProject)
        try FileManager.default.copyItem(at: media, to: movedMedia)

        let loaded = try ProjectIO.load(from: movedProject)
        let resolved = loaded.assets[0].url(relativeTo: moved)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }
}

/// 書類バンドル（.nanovid パッケージ）。
///
///     作品.nanovid/
///       project.json
///       Recordings/
struct ProjectPackageTests {

    private func makeTempDir() throws -> URL {
        // /var → /private/var の言い換えで path の比較がずれないよう、先にほどいておく。
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nanovid-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audioAsset(at url: URL) -> MediaAsset {
        MediaAsset(path: url.path, displayName: url.lastPathComponent, kind: .audio,
                   duration: 3, naturalSize: nil, hasAudio: true, hasVideo: false)
    }

    /// 書類の中に録音を 1 つ置く。録音のときと同じ場所・同じ名前の付け方。
    private func record(_ name: String, in package: URL, contents: String = "wav") throws -> URL {
        let dir = ProjectIO.recordingsDirectory(in: package)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// 古い版が書いていたのと同じ形（JSON 1 ファイル）で置く。
    private func writeLegacy(_ project: Project, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    @Test("保存するとパッケージになり、中身は決まった名前のファイル")
    func savesAsPackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var project = Project.starter()
        project.name = "書類の名前に引きずられない"
        let url = dir.appendingPathComponent("作品.nanovid")
        try ProjectIO.save(project, to: url)

        #expect(isDirectory(url))
        #expect(ProjectIO.isPackage(url))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["project.json"])
        let json = try Data(contentsOf: url.appendingPathComponent("project.json"))
        #expect(try JSONDecoder().decode(Project.self, from: json).name == project.name)
        #expect(try ProjectIO.load(from: url).name == project.name)
    }

    @Test("書類の中の録音は、書類からの相対パスで保存され、開き直すと読める")
    func embeddedRecordingRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: url)
        let recording = try record("rec-1.wav", in: url)

        var project = Project.starter()
        var asset = audioAsset(at: recording)
        asset.bookmark = MediaBookmark.make(for: recording)
        project.assets = [asset]
        let saved = try ProjectIO.save(project, to: url, previous: url)

        // ファイルの上では相対パスと目印。bookmark は持たない。
        let json = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let onDisk = try JSONDecoder().decode(Project.self, from: json)
        #expect(onDisk.assets[0].path == "Recordings/rec-1.wav")
        #expect(onDisk.assets[0].embedded == true)
        #expect(onDisk.assets[0].bookmark == nil)

        // 読み込むと、今までと同じ扱い方（書類のあるフォルダを基準に解決）で届く。
        let loaded = try ProjectIO.load(from: url)
        #expect(loaded.assets[0].embedded == nil)
        #expect(loaded.assets[0].url(relativeTo: dir).path == recording.path)
        #expect(loaded == saved, "save の返り値は、読み直したものと同じ")
        // 上書きで録音が消えていない。
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }

    @Test("書類の名前を変えても・別の場所へ動かしても、中の録音を読める")
    func renamedPackageKeepsRecordings() throws {
        let dir = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let url = dir.appendingPathComponent("before.nanovid")
        try ProjectIO.save(Project.starter(), to: url)
        var project = Project.starter()
        project.assets = [audioAsset(at: try record("rec-1.wav", in: url, contents: "中身"))]
        try ProjectIO.save(project, to: url, previous: url)

        let moved = elsewhere.appendingPathComponent("after.nanovid")
        try FileManager.default.moveItem(at: url, to: moved)

        let resolved = try ProjectIO.load(from: moved).assets[0].url(relativeTo: elsewhere)
        #expect(resolved.path == moved.appendingPathComponent("Recordings/rec-1.wav").path)
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "中身")
    }

    @Test("別名で保存すると、録音も新しい書類の中へ写る")
    func saveAsCopiesRecordings() throws {
        let dir = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let original = dir.appendingPathComponent("one.nanovid")
        try ProjectIO.save(Project.starter(), to: original)
        let recording = try record("rec-1.wav", in: original, contents: "中身")
        var project = Project.starter()
        project.assets = [audioAsset(at: recording)]
        try ProjectIO.save(project, to: original, previous: original)
        project = try ProjectIO.load(from: original)

        let copy = elsewhere.appendingPathComponent("two.nanovid")
        let saved = try ProjectIO.save(project, to: copy, previous: original)

        let copied = copy.appendingPathComponent("Recordings/rec-1.wav")
        #expect(saved.assets[0].path == copied.path, "メモリの上でも新しい書類の中を指す")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "中身")
        // 元の書類はそのまま。
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(try ProjectIO.load(from: original).assets[0].path == recording.path)

        // 元を消しても、新しい書類だけで完結している。
        try FileManager.default.removeItem(at: original)
        let loaded = try ProjectIO.load(from: copy)
        #expect(MediaAccess.isReachable(loaded.assets[0].url(relativeTo: elsewhere)))
    }

    @Test("別名で保存しても、相対パスの素材は同じファイルを指す")
    func saveAsElsewhereKeepsRelativeAssets() throws {
        let dir = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let media = dir.appendingPathComponent("footage/clip.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: media)
        var project = Project.starter()
        project.assets = [MediaAsset(path: media.path, displayName: "clip", kind: .video,
                                     duration: 5, naturalSize: nil, hasAudio: false, hasVideo: true)]
        let original = dir.appendingPathComponent("one.nanovid")
        try ProjectIO.save(project, to: original)
        project = try ProjectIO.load(from: original)
        #expect(project.assets[0].path == "footage/clip.mp4")

        // 別のフォルダへ。相対パスのままだと、新しい場所を基準に探して見失う。
        let copy = elsewhere.appendingPathComponent("two.nanovid")
        let saved = try ProjectIO.save(project, to: copy, previous: original)
        #expect(saved.assets[0].url(relativeTo: elsewhere).path == media.path)
        #expect(try ProjectIO.load(from: copy).assets[0].url(relativeTo: elsewhere).path == media.path)
    }

    @Test("別名で保存で別の書類を置き換えると、前の中身は残らない")
    func saveAsReplacesAnotherPackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mine = dir.appendingPathComponent("mine.nanovid")
        try ProjectIO.save(Project.starter(), to: mine)
        let other = dir.appendingPathComponent("other.nanovid")
        try ProjectIO.save(Project.starter(), to: other)
        let stale = try record("rec-old.wav", in: other)

        var project = try ProjectIO.load(from: mine)
        project.name = "こちらが残る"
        try ProjectIO.save(project, to: other, previous: mine)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try ProjectIO.load(from: other).name == "こちらが残る")
        // 置き換えの作業用フォルダを残していない。
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["mine.nanovid", "other.nanovid"])
    }

    // MARK: 古い形式

    @Test("古い形式（JSON 1 ファイル）を開ける")
    func loadsLegacyFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 古い版は録音を隣の Recordings/ に置き、相対パスで持っていた。
        let recording = dir.appendingPathComponent("Recordings/rec-old.wav")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("古い録音".utf8).write(to: recording)
        var project = Project.starter()
        project.name = "古い形式"
        var asset = audioAsset(at: recording)
        asset.path = "Recordings/rec-old.wav"
        project.assets = [asset]

        let url = dir.appendingPathComponent("old.nanovid")
        try writeLegacy(project, to: url)
        #expect(!ProjectIO.isPackage(url))

        let loaded = try ProjectIO.load(from: url)
        #expect(loaded == project)
        #expect(loaded.assets[0].url(relativeTo: dir).path == recording.path)
    }

    @Test("embedded の無い、以前の版の JSON をそのまま読める")
    func loadsJSONWithoutNewKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var project = Project.starter()
        project.assets = [audioAsset(at: dir.appendingPathComponent("a.wav"))]
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(project)) as! [String: Any]
        var assets = object["assets"] as! [[String: Any]]
        assets[0].removeValue(forKey: "embedded")
        assets[0].removeValue(forKey: "bookmark")
        object["assets"] = assets
        let url = dir.appendingPathComponent("old.nanovid")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        #expect(try ProjectIO.load(from: url).assets[0].path == project.assets[0].path)
    }

    @Test("古い形式を開いて保存すると、その場でパッケージになる")
    func legacyFileBecomesPackageOnSave() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recording = dir.appendingPathComponent("Recordings/rec-old.wav")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("古い録音".utf8).write(to: recording)
        var project = Project.starter()
        project.name = "古い形式"
        var asset = audioAsset(at: recording)
        asset.path = "Recordings/rec-old.wav"
        project.assets = [asset]
        let url = dir.appendingPathComponent("old.nanovid")
        try writeLegacy(project, to: url)

        let loaded = try ProjectIO.load(from: url)
        try ProjectIO.save(loaded, to: url, previous: url)

        #expect(ProjectIO.isPackage(url))
        let reloaded = try ProjectIO.load(from: url)
        #expect(reloaded.name == "古い形式")
        // 隣の録音は外の素材のまま。動かさないし、写さない。
        #expect(reloaded.assets[0].path == "Recordings/rec-old.wav")
        #expect(reloaded.assets[0].url(relativeTo: dir).path == recording.path)
        #expect(try String(contentsOf: recording, encoding: .utf8) == "古い録音")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["project.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["Recordings", "old.nanovid"])
    }

    @Test("書類の外を指す相対パスは、書類の中に読み替える")
    func embeddedPathCannotEscapeThePackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var project = Project.starter()
        var asset = audioAsset(at: dir.appendingPathComponent("x.wav"))
        asset.path = "../../outside.wav"
        asset.embedded = true
        project.assets = [asset]
        let url = dir.appendingPathComponent("evil.nanovid")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: url.appendingPathComponent("project.json"))

        let loaded = try ProjectIO.load(from: url)
        #expect(loaded.assets[0].path == url.appendingPathComponent("outside.wav").path)
    }

    // MARK: 録音の置き場（EditorStore）

    @Test("録音は書類の中の Recordings に置く")
    @MainActor
    func recordingGoesInsideThePackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: url)
        let store = EditorStore()
        store.open(url: url)

        let recording = try #require(store.recordingURL())
        #expect(recording.deletingLastPathComponent().path
                == url.appendingPathComponent("Recordings").path)
        #expect(recording.pathExtension == "wav")
        #expect(isDirectory(recording.deletingLastPathComponent()))
    }

    @Test("古い形式を開いて録音すると、先にパッケージへ保存し直す")
    @MainActor
    func recordingConvertsLegacyFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("old.nanovid")
        try writeLegacy(Project.starter(), to: url)
        let store = EditorStore()
        store.open(url: url)
        #expect(!ProjectIO.isPackage(url))

        let recording = try #require(store.recordingURL())
        #expect(ProjectIO.isPackage(url))
        #expect(recording.path.hasPrefix(url.path + "/Recordings/"))
        #expect(!store.hasUnsavedChanges)
    }

    @Test("別名で保存すると、開いている書類も素材の場所も新しいほうへ移る")
    @MainActor
    func storeSaveAsRebasesAssets() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("one.nanovid")
        try ProjectIO.save(Project.starter(), to: original)
        let store = EditorStore()
        store.open(url: original)
        let recording = try #require(store.recordingURL())
        try Data("中身".utf8).write(to: recording)
        store.project.assets.append(audioAsset(at: recording))

        let copy = dir.appendingPathComponent("two.nanovid")
        #expect(store.saveAs(to: copy))

        #expect(store.documentURL?.path == copy.path)
        #expect(!store.hasUnsavedChanges)
        let moved = try #require(store.project.assets.last).url(relativeTo: store.baseURL)
        #expect(moved.path == copy.appendingPathComponent("Recordings")
            .appendingPathComponent(recording.lastPathComponent).path)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "中身")
    }
}
