import Testing
import Foundation
@testable import Nanovid

/// 録音した音声を書類の外へ取り出す（RecordingExport）。
struct RecordingExportTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nanovid-recexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audioAsset(at url: URL, kind: AssetKind = .audio) -> MediaAsset {
        MediaAsset(path: url.path, displayName: url.lastPathComponent, kind: kind,
                   duration: 3, naturalSize: nil, hasAudio: true, hasVideo: kind == .video)
    }

    private func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// 録音を 2 つ持つパッケージ書類を開いた store。取り込んだだけの音声も 1 つ混ぜる。
    @MainActor
    private func storeWithRecordings(in dir: URL) throws -> (EditorStore, recordings: [MediaAsset], imported: MediaAsset) {
        let package = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: package)
        let folder = ProjectIO.recordingsDirectory(in: package)
        let first = audioAsset(at: try write("一つ目", to: folder.appendingPathComponent("rec-20261110-100000.wav")))
        let second = audioAsset(at: try write("二つ目", to: folder.appendingPathComponent("rec-20261110-100500.wav")))
        let imported = audioAsset(at: try write("BGM", to: dir.appendingPathComponent("bgm.mp3")))
        var project = Project.starter()
        project.assets = [first, imported, second]
        try ProjectIO.save(project, to: package, previous: package)
        let store = EditorStore()
        store.open(url: package)
        return (store, [first, second], imported)
    }

    // MARK: 見分け

    @Test("書類の中の Recordings にある音声は録音")
    func embeddedAudioIsARecording() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: package)
        // 名前が録音の形でなくても、置き場所で分かる。
        let inside = ProjectIO.recordingsDirectory(in: package).appendingPathComponent("narration.wav")
        #expect(RecordingExport.isRecording(audioAsset(at: inside), document: package))
    }

    @Test("以前の版が書類の外に置いた録音も、名前で録音と分かる")
    func legacyRecordingsAreRecognizedByName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("old.nanovid")
        try JSONEncoder().encode(Project.starter()).write(to: legacy)

        // 隣の Recordings/ に相対パスで。
        var beside = audioAsset(at: dir.appendingPathComponent("Recordings/rec-20260901-093000.wav"))
        beside.path = "Recordings/rec-20260901-093000.wav"
        #expect(RecordingExport.isRecording(beside, document: legacy))
        // ユーザーが選んだ別のフォルダに絶対パスで。
        let elsewhere = audioAsset(at: URL(fileURLWithPath: "/Users/someone/Music/rec-20260901-093000.wav"))
        #expect(RecordingExport.isRecording(elsewhere, document: legacy))
        // まだ保存していないプロジェクトでも。
        #expect(RecordingExport.isRecording(elsewhere, document: nil))
    }

    @Test("取り込んだだけの素材は録音ではない")
    func importedMediaIsNotARecording() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("movie.nanovid")
        try ProjectIO.save(Project.starter(), to: package)

        #expect(!RecordingExport.isRecording(audioAsset(at: dir.appendingPathComponent("bgm.mp3")),
                                             document: package))
        #expect(!RecordingExport.isRecording(audioAsset(at: dir.appendingPathComponent("recording.wav")),
                                             document: package))
        // 名前が似ていても、動画は録音ではない。
        let video = audioAsset(at: dir.appendingPathComponent("rec-20260901-093000.wav"), kind: .video)
        #expect(!RecordingExport.isRecording(video, document: package))
    }

    // MARK: 写す

    @Test("1 つを、選んだ名前と場所へ写す。元は残る")
    func copiesOneToTheChosenName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("中身", to: dir.appendingPathComponent("in/rec-20261110-100000.wav"))
        let destination = dir.appendingPathComponent("ナレーション.wav")

        try RecordingExport.copy(source, to: destination)
        #expect(try read(destination) == "中身")
        #expect(try read(source) == "中身")

        // 保存パネルで「置き換える」を選んだあとは、置き換える。
        _ = try write("新しい中身", to: source)
        try RecordingExport.copy(source, to: destination)
        #expect(try read(destination) == "新しい中身")
    }

    @Test("同じ場所を選んでも、元のファイルを消さない")
    func copyingOntoItselfKeepsTheFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("中身", to: dir.appendingPathComponent("rec-20261110-100000.wav"))
        try RecordingExport.copy(source, to: source)
        #expect(try read(source) == "中身")
    }

    @Test("まとめて写すときは、同じ名前があっても上書きせず番号を付ける")
    func copyingManyNeverOverwrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try write("A", to: dir.appendingPathComponent("in/rec-1.wav"))
        let b = try write("B", to: dir.appendingPathComponent("in/rec-2.wav"))
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try write("前からあったもの", to: out.appendingPathComponent("rec-1.wav"))

        let written = try RecordingExport.copy([a, b], into: out)
        #expect(written.map(\.lastPathComponent) == ["rec-1 2.wav", "rec-2.wav"])
        #expect(try read(out.appendingPathComponent("rec-1.wav")) == "前からあったもの")
        #expect(try read(written[0]) == "A")

        // もう一度書き出しても、前の分を消さない。
        let again = try RecordingExport.copy([a, b], into: out)
        #expect(again.map(\.lastPathComponent) == ["rec-1 3.wav", "rec-2 2.wav"])
        #expect(try names(in: out).count == 5)
    }

    @Test("ファイルが消えている録音があれば、何も写さずに名前を言う")
    func missingSourceFailsBeforeCopying() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = try write("A", to: dir.appendingPathComponent("in/rec-1.wav"))
        let missing = dir.appendingPathComponent("in/rec-gone.wav")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        #expect(throws: RecordingExport.Problem.self) {
            try RecordingExport.copy([present, missing], into: out)
        }
        #expect(try names(in: out).isEmpty)
        do {
            try RecordingExport.copy(missing, to: out.appendingPathComponent("x.wav"))
            Issue.record("消えているのに写せた")
        } catch {
            #expect(error.localizedDescription.contains("rec-gone.wav"))
        }
    }

    // MARK: store を通して

    @Test("書類の中の録音を、選んだフォルダへまとめて書き出す")
    @MainActor
    func storeExportsEmbeddedRecordings() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, recordings, imported) = try storeWithRecordings(in: dir)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        #expect(store.recordings().map(\.id) == recordings.map(\.id))
        // 録音でないものを一緒に選んでいても、録音だけが出る。
        let written = try store.exportRecordings(Set(recordings.map(\.id) + [imported.id]), into: out)
        #expect(written.map(\.lastPathComponent) == ["rec-20261110-100000.wav", "rec-20261110-100500.wav"])
        #expect(try read(written[0]) == "一つ目")
        #expect(try read(written[1]) == "二つ目")

        // 選んだものだけ。
        let one = dir.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try store.exportRecordings([recordings[1].id], into: one)
        #expect(try names(in: one) == ["rec-20261110-100500.wav"])

        // 書類は変わらない（録音は中に残り、未保存にもならない）。
        let package = try #require(store.documentURL)
        #expect(try names(in: ProjectIO.recordingsDirectory(in: package)).count == 2)
        #expect(!store.hasUnsavedChanges)
    }

    @Test("古い形式のプロジェクトの、外にある録音も同じように書き出せる")
    @MainActor
    func storeExportsLegacyRecordings() throws {
        let dir = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        // 以前の版: 隣の Recordings/（相対パス）と、ユーザーが選んだフォルダ（絶対パス）。
        _ = try write("隣", to: dir.appendingPathComponent("Recordings/rec-20260901-093000.wav"))
        var beside = audioAsset(at: dir.appendingPathComponent("Recordings/rec-20260901-093000.wav"))
        beside.path = "Recordings/rec-20260901-093000.wav"
        let chosen = audioAsset(at: try write("選んだ先", to: elsewhere.appendingPathComponent("rec-20260902-110000.wav")))
        var project = Project.starter()
        project.assets = [beside, chosen]
        let legacy = dir.appendingPathComponent("old.nanovid")
        try JSONEncoder().encode(project).write(to: legacy)

        let store = EditorStore()
        store.open(url: legacy)
        #expect(store.recordings().count == 2)

        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let written = try store.exportRecordings(into: out)
        #expect(try written.map(read) == ["隣", "選んだ先"])
        // 書き出しただけでは、古い形式のまま。
        #expect(!ProjectIO.isPackage(legacy))
    }
}
