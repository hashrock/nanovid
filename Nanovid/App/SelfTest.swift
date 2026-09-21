import AVFoundation
import Foundation

/// `Nanovid --selftest <出力ディレクトリ>` で実行される検証用の経路。
/// 1) テキストのみのプロジェクトを書き出す（映像トラックが無い場合の経路）
/// 2) 1 の出力と生成した WAV を素材に、映像＋音声＋テロップを重ねて書き出す
enum SelfTest {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--selftest") else { return false }
        let dir = URL(fileURLWithPath: args.count > idx + 1 ? args[idx + 1] : NSTemporaryDirectory())
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do { try await run(in: dir) } catch { failure = error }
            sem.signal()
        }
        sem.wait()
        if let failure {
            FileHandle.standardError.write("FAIL: \(failure.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
        print("SELFTEST OK")
        exit(0)
    }

    private static func run(in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // --- 1) テキストのみ ---
        var p1 = Project.starter()
        p1.canvas.backgroundColor = RGBAColor(hex: "#101820")!
        let title = p1.textTemplates[1]
        var titleClip = Clip(start: 0, duration: 3, content: .text(TextInstance(
            templateID: title.id,
            props: ["title": .string("nanovid 自己テスト"), "subtitle": .string("text only pass")]
        )))
        titleClip.fade = Fade(inDuration: 0.4, outDuration: 0.4)
        p1.tracks[1].clips = [titleClip]

        let textOnly = dir.appendingPathComponent("01-text-only.mp4")
        try await Exporter().export(project: p1, baseURL: nil, to: textOnly,
                                    settings: ExportSettings()) { _ in }
        try report(textOnly, expectDuration: 3, expectSize: p1.canvas.size)

        // --- 2) 映像＋音声＋テロップ ---
        let wav = dir.appendingPathComponent("tone.wav")
        try makeTone(at: wav, seconds: 3)

        var p2 = Project.starter()
        p2.canvas = CanvasSpec(width: 1080, height: 1920, fps: 30)  // ショート解像度で縦横の扱いも確認
        let videoAsset = MediaAsset(path: textOnly.path, displayName: "01", kind: .video,
                                    duration: 3, naturalSize: CGSize(width: 1920, height: 1080),
                                    hasAudio: false, hasVideo: true)
        let audioAsset = MediaAsset(path: wav.path, displayName: "tone", kind: .audio,
                                    duration: 3, naturalSize: nil, hasAudio: true, hasVideo: false)
        p2.assets = [videoAsset, audioAsset]

        var vClip = Clip(start: 0, duration: 2.5, content: .media(assetID: videoAsset.id, sourceStart: 0.2))
        vClip.fade = Fade(inDuration: 0.3, outDuration: 0.3)
        p2.tracks[0].clips = [vClip]

        let sub = p2.textTemplates[0]
        var subClip = Clip(start: 0.5, duration: 2.0, content: .text(TextInstance(
            templateID: sub.id,
            props: ["text": .string("字幕の背景が文字幅に追従する"),
                    "plateColor": .color(RGBAColor(hex: "#1E88E5CC")!)]
        )))
        subClip.fade = Fade(inDuration: 0.2, outDuration: 0.2)
        p2.tracks[1].clips = [subClip]

        var aClip = Clip(start: 0, duration: 2.5, content: .media(assetID: audioAsset.id, sourceStart: 0))
        aClip.volume = 0.5
        aClip.fade = Fade(inDuration: 0.5, outDuration: 0.5)
        p2.tracks[2].clips = [aClip]

        let composed = dir.appendingPathComponent("02-composed.mp4")
        try await Exporter().export(project: p2, baseURL: nil, to: composed,
                                    settings: ExportSettings(codec: .h264, quality: .high)) { _ in }
        try report(composed, expectDuration: 2.5, expectSize: p2.canvas.size)

        // --- 3) ギャップと重なり ---
        var p3 = Project.starter()
        p3.canvas = CanvasSpec(width: 1280, height: 720, fps: 30)
        p3.canvas.backgroundColor = RGBAColor(hex: "#803010")!
        p3.assets = [videoAsset]
        // 0.0-1.0 に映像、1.0-2.0 は何も無い（背景色が出るはず）、2.0-3.0 に再び映像。
        p3.tracks[0].clips = [
            Clip(start: 0, duration: 1.0, content: .media(assetID: videoAsset.id, sourceStart: 0)),
            Clip(start: 2.0, duration: 1.0, content: .media(assetID: videoAsset.id, sourceStart: 1.0)),
        ]
        // 同じ時間帯に 2 枚重ねて、前面／背面の順序を確認する。
        var overlay = Clip(start: 2.0, duration: 1.0,
                           content: .media(assetID: videoAsset.id, sourceStart: 0))
        overlay.transform = Transform2D(position: CGPoint(x: 0.2, y: 0.2), scale: 0.4, rotation: 0)
        p3.tracks[1].clips = [
            overlay,
            Clip(start: 1.2, duration: 0.6, content: .text(TextInstance(
                templateID: p3.textTemplates[0].id,
                props: ["text": .string("ギャップ中"), "plateColor": .color(.clear)]))),
        ]

        let gapped = dir.appendingPathComponent("03-gap-overlap.mp4")
        try await Exporter().export(project: p3, baseURL: nil, to: gapped,
                                    settings: ExportSettings()) { _ in }
        try report(gapped, expectDuration: 3.0, expectSize: p3.canvas.size)

        // --- 4) 保存と読み込みの往復 ---
        let projectFile = dir.appendingPathComponent("roundtrip.nanovid")
        try ProjectIO.save(p3, to: projectFile)
        let reloaded = try ProjectIO.load(from: projectFile)
        guard reloaded.tracks.map(\.clips.count) == p3.tracks.map(\.clips.count),
              reloaded.canvas == p3.canvas,
              reloaded.textTemplates.count == p3.textTemplates.count else {
            throw Fail("保存と読み込みで内容が一致しません")
        }
        // 相対パス化が効いているか（プロジェクトと同階層の素材）。
        let localCopy = dir.appendingPathComponent("local.mp4")
        try? FileManager.default.removeItem(at: localCopy)
        try FileManager.default.copyItem(at: textOnly, to: localCopy)
        var p4 = p3
        p4.assets = [MediaAsset(path: localCopy.path, displayName: "local", kind: .video,
                                duration: 3, naturalSize: nil, hasAudio: false, hasVideo: true)]
        try ProjectIO.save(p4, to: projectFile)
        let reloaded4 = try ProjectIO.load(from: projectFile)
        guard reloaded4.assets.first?.path == "local.mp4" else {
            throw Fail("相対パスになっていません: \(reloaded4.assets.first?.path ?? "nil")")
        }
        print("  roundtrip ok (相対パス: \(reloaded4.assets.first!.path))")
    }

    private static func report(_ url: URL, expectDuration: Double, expectSize: CGSize) throws {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var line = ""
        var err: Error?
        Task {
            do {
                let d = try await asset.load(.duration).secondsOrZero
                let vt = try await asset.loadTracks(withMediaType: .video).first
                let at = try await asset.loadTracks(withMediaType: .audio).first
                let size = try await vt?.load(.naturalSize) ?? .zero
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                line = String(format: "  %@  %.2fs  %.0fx%.0f  audio=%@  %d KB",
                              url.lastPathComponent, d, size.width, size.height,
                              at == nil ? "no" : "yes", (bytes ?? 0) / 1024)
                if abs(d - expectDuration) > 0.2 { err = Fail("duration \(d) != \(expectDuration)") }
                if size != expectSize { err = Fail("size \(size) != \(expectSize)") }
            } catch { err = error }
            sem.signal()
        }
        sem.wait()
        print(line)
        if let err { throw err }
    }

    struct Fail: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    /// 検証用の 440Hz トーンを WAV で書き出す。
    private static func makeTone(at url: URL, seconds: Double) throws {
        let sampleRate = 48000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate)) * 0.3
            }
        }
        try file.write(from: buf)
    }
}
