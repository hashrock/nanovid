import Testing
import AVFoundation
import Foundation
@testable import Nanovid

/// 音声だけの書き出し（AudioExporter）。実際に書き出して、長さと中身を見る。
///
/// 制限時間を付けてある。書き出しは読み手と書き手の受け渡しで進むので、噛み合わないと
/// 失敗ではなく「いつまでも終わらない」になる。そのとき名前が残るように。
@Suite(.tags(.media), TestTier.heavy, .timeLimit(.minutes(2)))
struct AudioExportTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nanovid-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 2 秒の正弦波を、音声トラックの start 秒に置いたプロジェクト。
    private func project(toneAt start: Double, in dir: URL,
                         configure: (inout Project) -> Void = { _ in }) async throws -> Project {
        let tone = dir.appendingPathComponent("tone.wav")
        if !FileManager.default.fileExists(atPath: tone.path) {
            try TestAudio.writeTone(to: tone, seconds: 2)
        }
        let asset = try await AssetCache.shared.inspect(url: tone)
        var project = Project.starter()
        project.canvas = CanvasSpec(width: 160, height: 90, fps: 30)
        project.assets = [asset]
        let audio = try #require(project.tracks.firstIndex { $0.kind == .audio })
        project.tracks[audio].clips = [
            Clip(start: start, duration: 2, content: .media(assetID: asset.id, sourceStart: 0))
        ]
        configure(&project)
        return project
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test("M4A と WAV のどちらでも、タイムラインの音が同じ長さで出る",
          arguments: AudioExportFormat.allCases)
    func exportsTheMix(format: AudioExportFormat) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try await project(toneAt: 0, in: dir)
        let output = dir.appendingPathComponent("out.\(format.fileExtension)")

        try await AudioExporter().export(project: project, baseURL: dir, to: output, format: format)

        #expect(abs(try await duration(of: output) - 2) < 0.06)
        let samples = try #require(try await TestAudio.samples(of: output))
        #expect(TestAudio.peak(samples, from: 0.2, to: 1.8) > 0.4)
        // 映像トラックは無い。
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).isEmpty)
    }

    @Test("WAV は 48kHz・ステレオ・16bit の PCM")
    func wavIsPlainPCM() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.wav")
        try await AudioExporter().export(project: try await project(toneAt: 0, in: dir),
                                         baseURL: dir, to: output, format: .wav)
        let format = try AVAudioFile(forReading: output).fileFormat
        #expect(format.sampleRate == 48000)
        #expect(format.channelCount == 2)
        #expect(format.settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
        #expect(format.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test("書き出す範囲に従う。範囲の頭がファイルの 0 秒になる")
    func followsTheOutputRange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 音は 1〜3 秒。範囲は 0.5〜2 秒なので、出力は 1.5 秒で、頭の 0.5 秒は無音。
        let project = try await project(toneAt: 1, in: dir) { $0.outputRange = OutputRange(start: 0.5, end: 2) }
        let output = dir.appendingPathComponent("out.wav")

        try await AudioExporter().export(project: project, baseURL: dir, to: output, format: .wav)

        #expect(abs(try await duration(of: output) - 1.5) < 0.01)
        let samples = try #require(try await TestAudio.samples(of: output))
        #expect(TestAudio.peak(samples, from: 0, to: 0.45) < 0.01, "音の前は無音")
        #expect(TestAudio.peak(samples, from: 0.55, to: 1.45) > 0.4, "範囲の中の音が入っている")
    }

    @Test("音が終わったあとも、書き出す範囲の終わりまで無音で埋まる")
    func padsWithSilenceToTheEndOfTheRange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 音は 0〜2 秒、テロップが 4 秒まで続く。動画は 4 秒なので、音声も 4 秒。
        let project = try await project(toneAt: 0, in: dir) { p in
            let template = p.textTemplates[0]
            p.tracks[1].clips = [Clip(start: 0, duration: 4,
                                      content: .text(TextInstance(templateID: template.id)))]
        }
        #expect(project.duration == 4)
        for format in AudioExportFormat.allCases {
            let output = dir.appendingPathComponent("out.\(format.fileExtension)")
            try await AudioExporter().export(project: project, baseURL: dir, to: output, format: format)
            #expect(abs(try await duration(of: output) - 4) < 0.06, "\(format)")
            let samples = try #require(try await TestAudio.samples(of: output))
            #expect(TestAudio.peak(samples, from: 0.2, to: 1.8) > 0.4)
            #expect(TestAudio.peak(samples, from: 2.2, to: 3.8) < 0.01)
        }
    }

    @Test("ミュートしたトラックの音は入らない。音量も効く")
    func respectsMuteAndVolume() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 0〜2 秒はミュートしたトラック、2〜4 秒は鳴らすトラック。
        let mixed = try await project(toneAt: 0, in: dir) { p in
            let audio = p.tracks.firstIndex { $0.kind == .audio }!
            var second = Track(name: "音声 2", kind: .audio)
            second.clips = p.tracks[audio].clips.map { clip in
                var moved = clip
                moved.id = UUID()
                moved.start = 2
                return moved
            }
            p.tracks[audio].isMuted = true
            p.tracks.append(second)
        }
        let output = dir.appendingPathComponent("mixed.wav")
        try await AudioExporter().export(project: mixed, baseURL: dir, to: output, format: .wav)
        let samples = try #require(try await TestAudio.samples(of: output))
        #expect(abs(Double(samples.count) / 48000 - 4) < 0.01)
        #expect(TestAudio.peak(samples, from: 0.1, to: 1.9) < 0.01, "ミュートした側は入らない")
        #expect(TestAudio.peak(samples, from: 2.1, to: 3.9) > 0.4)

        // 全部ミュートなら、聞こえる音が無いので断る。
        let muted = try await project(toneAt: 0, in: dir) { p in
            for i in p.tracks.indices where p.tracks[i].kind == .audio { p.tracks[i].isMuted = true }
        }
        await #expect(throws: TimelineAudioError.self) {
            try await AudioExporter().export(project: muted, baseURL: dir,
                                             to: dir.appendingPathComponent("muted.wav"), format: .wav)
        }

        // 音量を半分にすると、そのままのときの半分になる。
        let full = dir.appendingPathComponent("full.wav")
        try await AudioExporter().export(project: try await project(toneAt: 0, in: dir),
                                         baseURL: dir, to: full, format: .wav)
        let half = try await project(toneAt: 0, in: dir) { p in
            for i in p.tracks.indices where p.tracks[i].kind == .audio {
                for c in p.tracks[i].clips.indices { p.tracks[i].clips[c].volume = 0.5 }
            }
        }
        let halved = dir.appendingPathComponent("half.wav")
        try await AudioExporter().export(project: half, baseURL: dir, to: halved, format: .wav)
        let fullPeak = try #require(try await TestAudio.peak(of: full))
        let halfPeak = try #require(try await TestAudio.peak(of: halved))
        #expect(abs(halfPeak / fullPeak - 0.5) < 0.1, "そのまま \(fullPeak) / 半分 \(halfPeak)")
    }

    @Test("音声が無いタイムラインは、ファイルを作らずに断る")
    func refusesWithoutAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var project = Project.starter()
        let template = project.textTemplates[0]
        project.tracks[1].clips = [Clip(start: 0, duration: 1,
                                        content: .text(TextInstance(templateID: template.id)))]
        let output = dir.appendingPathComponent("out.m4a")
        await #expect(throws: TimelineAudioError.self) {
            try await AudioExporter().export(project: project, baseURL: dir, to: output, format: .m4a)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("store から書き出すと、終わったら進み具合の表示が消える")
    @MainActor
    func storeExport() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EditorStore()
        store.project = try await project(toneAt: 0, in: dir)
        #expect(store.canExportAudio)
        let output = dir.appendingPathComponent("out.m4a")
        try await store.exportAudio(to: output, format: .m4a)
        #expect(store.audioExportProgress == nil)
        #expect(try #require(try await TestAudio.peak(of: output)) > 0.4)
    }
}
