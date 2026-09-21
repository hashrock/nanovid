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
