import AppKit
import AVFoundation
import Foundation

/// `Nanovid --selftest <出力ディレクトリ>` で実行される検証用の経路。
/// 1) テキストのみのプロジェクトを書き出す（映像トラックが無い場合の経路）
/// 2) 1 の出力と生成した WAV を素材に、映像＋音声＋テロップを重ねて書き出す
enum SelfTest {

    /// `Nanovid --write-demo <ディレクトリ> [音声ファイル]` で、動作確認用の
    /// プロジェクトを書き出して終了する。音声を渡すと音声トラックに載せる。
    static func writeDemoIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--write-demo"), args.count > idx + 1 else { return false }
        let dir = URL(fileURLWithPath: args[idx + 1])
        let audio: URL? = args.count > idx + 2 ? URL(fileURLWithPath: args[idx + 2]) : nil
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var p = Project.starter()
            p.name = "demo"
            let lines = [
                (0.0, 2.4, "字幕", "はじめに"),
                (2.8, 3.2, "シンプル字幕", "縁取りだけのシンプル字幕"),
                (6.4, 2.6, "テロップ（左下）", "左下のテロップ"),
                (9.6, 3.4, "字幕", "最後のまとめ"),
            ]
            for (start, duration, templateName, text) in lines {
                let template = try template(templateName, in: p)
                p.tracks[1].clips.append(Clip(
                    start: start, duration: duration,
                    content: .text(TextInstance(templateID: template.id,
                                                props: ["text": .string(text)]))))
            }
            if let audio {
                let sem = DispatchSemaphore(value: 0)
                var asset: MediaAsset?
                Task.detached {
                    asset = try? await AssetCache.shared.inspect(url: audio)
                    sem.signal()
                }
                sem.wait()
                let kind: TrackKind = asset?.kind == .audio ? .audio : .video
                if let asset, let track = p.tracks.firstIndex(where: { $0.kind == kind }) {
                    p.assets.append(asset)
                    p.tracks[track].clips = [
                        Clip(name: asset.displayName, start: 0,
                             duration: asset.kind == .image ? 5 : asset.duration,
                             content: .media(assetID: asset.id, sourceStart: 0))
                    ]
                    // 素材を試すときはテロップが邪魔なので消しておく。
                    for i in p.tracks.indices where p.tracks[i].kind == .video && i != track {
                        p.tracks[i].clips = []
                    }
                }
            }

            let url = dir.appendingPathComponent("demo.nanovid")
            try ProjectIO.save(p, to: url)
            print(url.path)
            exit(0)
        } catch {
            FileHandle.standardError.write("FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// `Nanovid --transcribe <音声ファイル> [言語]` で書き起こしだけ試して終了する。
    /// 認識の具合と区切り方を、GUI を触らずに確かめるため。
    static func transcribeIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--transcribe"), args.count > idx + 1 else { return false }
        guard #available(macOS 26.0, *) else {
            FileHandle.standardError.write("FAIL: \(SubtitleGeneration.requirement)\n".data(using: .utf8)!)
            exit(1)
        }
        let url = URL(fileURLWithPath: args[idx + 1])
        let locale = Locale(identifier: args.count > idx + 2 ? args[idx + 2] : "ja-JP")

        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                var project = Project.starter()
                let asset = try await AssetCache.shared.inspect(url: url)
                project.assets = [asset]
                guard let track = project.tracks.firstIndex(where: { $0.kind == .audio }) else { return }
                project.tracks[track].clips = [
                    Clip(start: 0, duration: asset.duration,
                         content: .media(assetID: asset.id, sourceStart: 0))
                ]

                let words = try await Transcriber().transcribe(
                    project: project, baseURL: nil, locale: locale) { _ in }
                let lines = SubtitleSegmentation.lines(from: words)

                print("語 \(words.count) 個 → 字幕 \(lines.count) 枚")
                for line in lines {
                    print(String(format: "  %@ (%.1f秒) %@",
                                 Format.timecode(line.start, fps: 30),
                                 line.duration, line.text))
                }
            } catch {
                failure = error
            }
            sem.signal()
        }
        sem.wait()
        if let failure {
            FileHandle.standardError.write("FAIL: \(failure.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }

    /// `Nanovid --inspect <プロジェクト> [時刻]` で、組み上げた合成の中身を調べて終了する。
    /// プレビューが映らないときに、どこで止まっているのかを切り分けるため。
    static func inspectIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--inspect"), args.count > idx + 1 else { return false }
        let url = URL(fileURLWithPath: args[idx + 1])
        let at = args.count > idx + 2 ? (Double(args[idx + 2]) ?? 0) : 0

        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                let project = try ProjectIO.load(from: url)
                let base = url.deletingLastPathComponent()
                print("プロジェクト: \(project.name)  \(project.canvas.width)x\(project.canvas.height) / \(project.canvas.fps)fps")
                print("尺: \(String(format: "%.2f", project.duration)) 秒")

                for asset in project.assets {
                    let resolved = asset.url(relativeTo: base)
                    let exists = FileManager.default.fileExists(atPath: resolved.path)
                    print("  素材 \(exists ? "○" : "×") \(asset.kind.label) \(asset.displayName)")
                }

                let built = try await CompositionBuilder.build(project: project, baseURL: base)
                let videoTracks = built.composition.tracks(withMediaType: .video)
                let audioTracks = built.composition.tracks(withMediaType: .audio)
                print("合成: 映像トラック \(videoTracks.count) / 音声トラック \(audioTracks.count)")
                for track in videoTracks {
                    let segments = track.segments.filter { !$0.isEmpty }
                    print("  映像 id=\(track.trackID) 尺=\(String(format: "%.2f", track.timeRange.duration.secondsOrZero)) 区間=\(segments.count)")
                }

                let instructions = built.videoComposition.instructions
                print("命令: \(instructions.count) 個")
                var gap = false
                for i in 1..<max(1, instructions.count) {
                    if instructions[i].timeRange.start != instructions[i - 1].timeRange.end { gap = true }
                }
                print("  連続: \(gap ? "途切れあり" : "問題なし")")

                if let hit = instructions.compactMap({ $0 as? NanovidInstruction })
                    .first(where: { $0.timeRange.containsTime(at.cmTime) }) {
                    print("  \(String(format: "%.2f", at)) 秒の命令: レイヤー \(hit.layers.count) / 必要トラック \(hit.requiredSourceTrackIDs?.count ?? 0)")
                    for layer in hit.layers {
                        switch layer.source {
                        case .media(let id, _): print("    映像 trackID=\(id)")
                        case .text(let image, let rect):
                            print("    テキスト \(image.width)x\(image.height) at \(Int(rect.minX)),\(Int(rect.minY))")
                        }
                    }
                }

                // プレビューと同じ経路で 1 枚だけ描かせてみる。
                let generator = AVAssetImageGenerator(asset: built.composition)
                generator.videoComposition = built.videoComposition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                generator.appliesPreferredTrackTransform = false
                do {
                    let (image, actual) = try await generator.image(at: at.cmTime)
                    let out = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nanovid-inspect.png")
                    try NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:])!.write(to: out)
                    print("描画: 成功 \(image.width)x\(image.height) (実時刻 \(String(format: "%.2f", actual.secondsOrZero)) 秒)")
                    print("  \(out.path)")
                } catch {
                    print("描画: 失敗 \(error.localizedDescription)")
                }
            } catch {
                failure = error
            }
            sem.signal()
        }
        sem.wait()
        if let failure {
            FileHandle.standardError.write("FAIL: \(failure.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }

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

    /// テンプレートは名前で引く。添字だと、同梱テンプレートを足したときに
    /// 黙って別のテンプレートを使ってしまう。
    private static func template(_ name: String, in project: Project) throws -> TextTemplate {
        guard let found = project.textTemplates.first(where: { $0.name == name }) else {
            throw Fail("テンプレート「\(name)」が見つかりません")
        }
        return found
    }

    private static func run(in dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // --- 1) テキストのみ ---
        var p1 = Project.starter()
        p1.canvas.backgroundColor = RGBAColor(hex: "#101820")!
        let title = try template("タイトル", in: p1)
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

        let sub = try template("字幕", in: p2)
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
                templateID: try template("シンプル字幕", in: p3).id,
                props: ["text": .string("縁取りのテスト Outline")]))),
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
