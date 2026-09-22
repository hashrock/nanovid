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
                (0.0, 2.4, TextTemplate.subtitle().name, "はじめに"),
                (2.8, 3.2, TextTemplate.plainSubtitle().name, "縁取りだけのシンプル字幕"),
                (6.4, 2.6, TextTemplate.lowerLeftNote().name, "左下のテロップ"),
                (9.6, 3.4, TextTemplate.subtitle().name, "最後のまとめ"),
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

                // 進み具合をそのまま出す。画面に何が見えるかをここで確かめられる。
                let reported = Mutex<String?>(nil)
                let words = try await Transcriber().transcribe(
                    project: project, baseURL: nil, locale: locale
                ) { progress in
                    let line = progress.text
                    reported.withLock { last in
                        guard last != line else { return }
                        last = line
                        print("  … \(line)")
                    }
                }
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
                print("尺: \(String(format: "%.2f", project.duration)) 秒"
                      + (project.hasExplicitOutputRange
                         ? String(format: "（範囲 %.2f〜%.2f / 中身は %.2f 秒まで）",
                                  project.outputStart, project.outputEnd, project.contentEnd)
                         : "（クリップに追従）"))

                for asset in project.assets {
                    let resolved = asset.url(relativeTo: base)
                    let exists = FileManager.default.fileExists(atPath: resolved.path)
                    print("  素材 \(exists ? "○" : "×") \(asset.kind.label) \(asset.displayName)")
                }

                // 編集のたびにこれを組み直すので、どれだけかかるかは体感に直結する。
                let started = Date()
                let built = try await CompositionBuilder.build(project: project, baseURL: base)
                let cold = Date().timeIntervalSince(started) * 1000
                // 2 回目は文字のラスタライズが temp に残っている状態。編集中はこちらの速さになる。
                let again = Date()
                _ = try await CompositionBuilder.build(project: project, baseURL: base)
                let warm = Date().timeIntervalSince(again) * 1000
                print(String(format: "組み立て: 初回 %.0f ms / 2 回目 %.0f ms", cold, warm))
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
                        case .still(let image):
                            print("    画像 \(image.width)x\(image.height)")
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
                    let firstStarted = Date()
                    let (image, actual) = try await generator.image(at: at.cmTime)
                    let first = Date().timeIntervalSince(firstStarted) * 1000
                    // 2 枚目はデコーダが起きている状態。スクラブ中の 1 コマはこちらに近い。
                    let nextStarted = Date()
                    _ = try await generator.image(at: (at + project.canvas.frameDuration).cmTime)
                    let next = Date().timeIntervalSince(nextStarted) * 1000
                    let out = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nanovid-inspect.png")
                    try NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:])!.write(to: out)
                    print("描画: 成功 \(image.width)x\(image.height) (実時刻 \(String(format: "%.2f", actual.secondsOrZero)) 秒)")
                    print(String(format: "  再生経路で 1 コマ: 初回 %.0f ms / 次のコマ %.0f ms", first, next))
                    print("  \(out.path)")

                    // 合成だけを直に呼んだときの速さ。素材のフレームは渡さないので、
                    // 映像レイヤーは飛ばされ、文字と背景の合成ぶんだけが出る。
                    if let instruction = built.videoComposition.instructions.first(where: {
                        $0.timeRange.start <= at.cmTime && at.cmTime < $0.timeRange.end
                    }) as? NanovidInstruction {
                        let compositor = NanovidCompositor()
                        _ = compositor.render(instruction: instruction, at: at)   // 温める
                        let composeStarted = Date()
                        for _ in 0..<10 { _ = compositor.render(instruction: instruction, at: at) }
                        let perFrame = Date().timeIntervalSince(composeStarted) * 100
                        let textLayers = instruction.layers.filter { $0.trackID == nil }.count
                        print(String(format: "  合成だけ（文字 %d 枚＋背景）: 1 コマ %.1f ms", textLayers, perFrame))
                    }
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
        try await timedExport(project: p1, to: textOnly,
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

        let sub = try template(TextTemplate.subtitle().name, in: p2)
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
        try await timedExport(project: p2, to: composed,
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
                templateID: try template(TextTemplate.plainSubtitle().name, in: p3).id,
                props: ["text": .string("縁取りのテスト Outline")]))),
        ]

        let gapped = dir.appendingPathComponent("03-gap-overlap.mp4")
        try await timedExport(project: p3, to: gapped,
                                    settings: ExportSettings()) { _ in }
        try report(gapped, expectDuration: 3.0, expectSize: p3.canvas.size)

        // --- 4) 書き出す範囲 ---
        //
        // 1 秒ごとに見た目がはっきり違うタイムラインを作り、その 2.0〜3.0 秒だけを
        // 書き出す。範囲の先頭が出力の 0 秒に来ているかを、全体版のどの時刻と
        // いちばん近いかで確かめる。
        var p4 = Project.starter()
        p4.canvas = CanvasSpec(width: 640, height: 360, fps: 30)
        p4.canvas.backgroundColor = RGBAColor(hex: "#202020")!
        let bigTitle = try template("タイトル", in: p4)
        p4.tracks[1].clips = (0..<3).map { i in
            var clip = Clip(start: Double(i), duration: 1.0, content: .text(TextInstance(
                templateID: bigTitle.id,
                props: ["title": .string(["AAAA", "MMMM", "||||"][i]),
                        "subtitle": .string("\(i) 秒台")]
            )))
            // 範囲の端をまたぐフェードを入れる。ここを切り詰めると、
            // 切った先から改めて立ち上がって、全体版と画が食い違う。
            clip.fade = Fade(inDuration: 0.4, outDuration: 0.4)
            return clip
        }

        let whole = dir.appendingPathComponent("04-range-whole.mp4")
        try await timedExport(project: p4, to: whole,
                                    settings: ExportSettings()) { _ in }
        try report(whole, expectDuration: 3.0, expectSize: p4.canvas.size)

        // 範囲の頭をクリップの途中（フェードインの最中）に置く。
        // 端をそろえてしまうと、切り詰めの経路を通らない。
        var p4r = p4
        p4r.outputRange = OutputRange(start: 2.2, end: 3.0)
        let ranged = dir.appendingPathComponent("04-range-cut.mp4")
        try await timedExport(project: p4r, to: ranged,
                                    settings: ExportSettings()) { _ in }
        try report(ranged, expectDuration: 0.8, expectSize: p4.canvas.size)

        // 再エンコードを挟むので画素は完全には一致しない。絶対値ではなく、
        // 全体版のどの時刻といちばん近いかで判定する。
        let cutFrame = try await frame(of: ranged, at: 0.4)
        var scores: [(time: Double, diff: Double)] = []
        for t in [0.6, 1.6, 2.6] {
            scores.append((t, meanDifference(cutFrame, try await frame(of: whole, at: t))))
        }
        let detail = scores.map { String(format: "%.1fs=%.2f", $0.time, $0.diff) }.joined(separator: " ")
        let best = scores.min { $0.diff < $1.diff }!
        guard best.time == 2.6 else { throw Fail("範囲の先頭がずれています（\(detail)）") }

        // フェードの最中も含めて、範囲の中はどこも全体版と同じ画になること。
        // 切り詰め方を誤ると、ここで端だけが食い違う。
        var worst = (time: 0.0, diff: 0.0)
        for step in 0...16 {
            let inRange = Double(step) / 16 * 0.78
            let diff = meanDifference(try await frame(of: ranged, at: inRange),
                                      try await frame(of: whole, at: 2.2 + inRange))
            if diff > worst.diff { worst = (inRange, diff) }
        }
        // 正しく切り出せていれば、再エンコードの誤差ぶん（実測 0.05）しか出ない。
        // フェードの最中で切ると 0.4 前後まで広がるので、その間に線を引く。
        guard worst.diff < 0.2 else {
            throw Fail(String(format: "範囲の中で画が食い違います（%.2f 秒で差 %.2f）",
                              worst.time, worst.diff))
        }
        print("  範囲書き出し ok (2.2〜3.0 秒、先頭合わせ \(detail)"
              + String(format: "、範囲内の最大差 %.2f)", worst.diff))

        // --- 5) 保存と読み込みの往復 ---
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
        var p5 = p3
        p5.assets = [MediaAsset(path: localCopy.path, displayName: "local", kind: .video,
                                duration: 3, naturalSize: nil, hasAudio: false, hasVideo: true)]
        try ProjectIO.save(p5, to: projectFile)
        let reloaded4 = try ProjectIO.load(from: projectFile)
        guard reloaded4.assets.first?.path == "local.mp4" else {
            throw Fail("相対パスになっていません: \(reloaded4.assets.first?.path ?? "nil")")
        }
        print("  roundtrip ok (相対パス: \(reloaded4.assets.first!.path))")
    }

    /// 動画の指定時刻のフレームを取り出す。
    private static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: seconds.cmTime).image
    }

    /// 2 枚の画像の画素成分の平均差。再エンコードのぶん完全一致はしないので、
    /// 「どのフレームにいちばん近いか」を測るために使う。
    private static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            buffer.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return buffer
        }
        let pa = pixels(a), pb = pixels(b)
        let count = min(pa.count, pb.count)
        guard count > 0 else { return 255 }
        var total = 0
        for i in 0..<count { total += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(total) / Double(count)
    }

    /// 書き出しにかかった時間。report で「何倍速か」を出すために覚えておく。
    nonisolated(unsafe) private static var exportSeconds: [URL: Double] = [:]

    private static func timedExport(project: Project, to url: URL,
                                    settings: ExportSettings,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let started = Date()
        try await Exporter().export(project: project, baseURL: nil, to: url,
                                    settings: settings, progress: progress)
        exportSeconds[url] = Date().timeIntervalSince(started)
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
                let took = exportSeconds[url] ?? 0
                let speed = took > 0 ? d / took : 0
                line = String(format: "  %@  %.2fs  %.0fx%.0f  audio=%@  %d KB  (%.1f 秒, %.1f 倍速)",
                              url.lastPathComponent, d, size.width, size.height,
                              at == nil ? "no" : "yes", bytes / 1024, took, speed)
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

/// 小さな排他。進み具合の重複を落とすだけに使う。
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
