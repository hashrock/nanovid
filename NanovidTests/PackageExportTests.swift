import Testing
import AVFoundation
import Foundation
@testable import Nanovid

/// 書類をパッケージにしても、外へ出す道（MP4 の書き出し）が通ること。
///
/// 録音は書類の中（Recordings/）にあり、Finder からは見えない。それでも
/// 書き出した MP4 には入っていないといけない。保存して開き直した書類でも、
/// 名前を変えた書類でも同じ。
@Suite(.tags(.media, .render), TestTier.heavy)
struct PackageExportTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nanovid-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("書類の中の録音が、書き出した MP4 に入る（保存して開き直し、名前を変えたあとでも）")
    @MainActor
    func embeddedRecordingIsExported() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 書類を作り、録音と同じ手順で中に音声を置いてタイムラインへ載せる。
        let package = dir.appendingPathComponent("movie.nanovid")
        var starter = Project.starter()
        starter.canvas = CanvasSpec(width: 160, height: 90, fps: 30)
        try ProjectIO.save(starter, to: package)
        let store = EditorStore()
        store.open(url: package)
        let recording = try #require(store.recordingURL())
        try TestAudio.writeTone(to: recording, seconds: 1)
        let asset = try #require(await store.importAssets(urls: [recording]).first)
        let track = try #require(store.project.tracks.first { $0.kind == .audio })
        #expect(store.addMediaClip(assetID: asset.id, trackID: track.id, at: 0) != nil)
        #expect(store.save())

        // Finder で名前を変えて、開き直す。
        let renamed = dir.appendingPathComponent("renamed.nanovid")
        try FileManager.default.moveItem(at: package, to: renamed)
        let reopened = try ProjectIO.load(from: renamed)
        #expect(MediaAccess.unreachable(in: reopened, base: dir).isEmpty)

        // 書き出し先は書類の外（保存パネルで選ぶ場所の代わり）。
        let output = dir.appendingPathComponent("out.mp4")
        try await Exporter().export(project: reopened, baseURL: dir, to: output,
                                    settings: ExportSettings()) { _ in }

        let peak = try #require(try await TestAudio.peak(of: output), "書き出しに音声トラックが無い")
        #expect(peak > 0.2, "音声トラックはあるが、中身が無音（ピーク \(peak)）")
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1) < 0.2)
        // 書類の中に書き出しの中間ファイルを残していない。
        #expect(try FileManager.default.contentsOfDirectory(atPath: renamed.path).sorted()
                == ["Recordings", "project.json"])
    }
}
