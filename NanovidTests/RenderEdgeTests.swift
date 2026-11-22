import Testing
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import Nanovid

/// 末尾のコマの時刻。
struct LastFrameTests {

    @Test("コマ境界ちょうどで終わるなら、1 つ前のコマ")
    func onFrameBoundary() {
        let canvas = CanvasSpec(width: 16, height: 16, fps: 30)
        #expect(canvas.lastFrameStart(before: 2.0) == 59.0 / 30)
        #expect(canvas.lastFrameStart(before: 1.0 / 30) == 0)
    }

    @Test("半端な終わりなら、そのコマの頭")
    func offFrameBoundary() {
        let canvas = CanvasSpec(width: 16, height: 16, fps: 30)
        #expect(canvas.lastFrameStart(before: 2.01) == 2.0)
        #expect(canvas.lastFrameStart(before: 0.001) == 0)
    }

    @Test("尺が無ければ 0")
    func empty() {
        #expect(CanvasSpec().lastFrameStart(before: 0) == 0)
        #expect(CanvasSpec().lastFrameStart(before: -1) == 0)
    }

    @Test("最後のコマは必ず尺の内側で、次のコマは尺に届く", arguments: PropertyRuns.seeds(200))
    func alwaysInside(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed))
        let canvas = CanvasSpec(width: 16, height: 16, fps: g.pick([24, 25, 30, 60]))
        let end = g.chance(0.5)
            ? Double(g.int(in: 1...900)) / Double(canvas.fps)
            : g.double(in: 0.01...30)
        let last = canvas.lastFrameStart(before: end)
        #expect(last < end, "seed \(seed): \(last) が尺 \(end) の外")
        #expect(last + canvas.frameDuration >= end - 1e-9,
                "seed \(seed): \(last) の次のコマもまだ尺 \(end) の内側")
    }
}

/// 区間の判定を、境界と同じ丸めた時刻で行うこと。
struct InstructionPlanRoundingTests {

    @Test("区間の構成は、丸めたレイヤーの端と食い違わない", arguments: PropertyRuns.seeds(300))
    func membershipMatchesRoundedEdges(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x7A11)
        // 1/600 秒の格子に乗らない端をわざと混ぜる。
        let layers = (0..<g.int(in: 1...8)).map { z in
            PlannedLayer(start: g.double(in: 0...3), duration: g.double(in: 0.0005...2), z: z)
        }
        let end = 6.0.cmTime
        for segment in InstructionPlan.segments(for: layers, end: end) {
            let expected = layers.indices.filter {
                let s = InstructionPlan.clamped(layers[$0].start, to: end)
                let e = InstructionPlan.clamped(layers[$0].end, to: end)
                return s < segment.range.end && segment.range.start < e
            }
            #expect(Set(segment.layerIndices) == Set(expected),
                    "seed \(seed): \(segment.range.start.seconds) 秒からの区間の構成が違う")
        }
    }
}

@Suite(.tags(.render), TestTier.heavy)
@MainActor
struct RenderEdgeTests {

    private func textProject() -> Project {
        var project = Project.starter()
        project.canvas = CanvasSpec(width: 320, height: 180, fps: 30)
        project.tracks[0].clips = []
        project.tracks[1].clips = [
            Clip(name: "字幕", start: 0, duration: 2,
                 content: .text(TextInstance(templateID: project.textTemplates[0].id,
                                             props: ["text": .string("末尾まで")]))),
        ]
        return project
    }

    @Test("描けなかったクリップは、黙って消さずに理由を残す")
    func skippedClipsAreReported() async throws {
        var project = textProject()
        let missing = Clip(name: "テンプレートなし", start: 0, duration: 1,
                           content: .text(TextInstance(templateID: UUID(), props: [:])))
        project.tracks[1].clips.append(missing)
        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        #expect(built.skipped.map(\.clipID) == [missing.id])
    }

    @Test("非表示のトラックはわざとなので、描けなかったものに数えない")
    func hiddenTracksAreNotSkipped() async throws {
        var project = textProject()
        project.tracks[1].isHidden = true
        project.tracks[0].clips = [project.tracks[1].clips[0]]
        project.tracks[0].isHidden = true
        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        #expect(built.skipped.isEmpty)
    }

    @Test("映像の無い区間は、土台のトラックだけを頼む")
    func textOnlySegmentsAskOnlyForTheSpacer() async throws {
        let built = try await CompositionBuilder.build(project: textProject(), baseURL: nil)
        let instructions = built.videoComposition.instructions.compactMap { $0 as? NanovidInstruction }
        let videoTrackIDs = built.composition.tracks(withMediaType: .video).map(\.trackID)
        try #require(!instructions.isEmpty)
        for instruction in instructions {
            let required = try #require(instruction.requiredSourceTrackIDs,
                                        "nil だと全トラックをデコードしてしまう")
            #expect(required.count == 1)
            let id = (required.first as? NSNumber)?.int32Value
            #expect(id.map(videoTrackIDs.contains) == true)
        }
    }

    @Test("終わりちょうどを描くと、最後のコマになる")
    func renderingAtTheEndGivesTheLastFrame() async throws {
        let renderer = try await FrameRenderer.make(project: textProject(), baseURL: nil)
        let end = renderer.built.duration
        let last = renderer.project.canvas.lastFrameStart(before: end)
        for path in FrameRenderer.Path.allCases {
            let atEnd = try #require(RGBAFrame(try await renderer.render(at: end, path: path)))
            let atLast = try #require(RGBAFrame(try await renderer.render(at: last, path: path)))
            #expect(atEnd.changedFraction(from: atLast) == 0, "\(path) で終わりの絵が最後のコマと違う")
        }
        #expect(renderer.describe(at: end + 5) != nil)
    }

    @Test("音声クリップのフェードが重なっていてもクラッシュせず組める")
    func overlappingAudioFadesDoNotCrash() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-fade-overlap-\(UUID().uuidString).wav")
        try TestAudio.writeTone(to: wav, seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav) }

        var project = Project.starter()
        project.canvas = CanvasSpec(width: 320, height: 180, fps: 30)
        let asset = MediaAsset(path: wav.path, displayName: "tone", kind: .audio,
                               duration: 2.0, naturalSize: nil, hasAudio: true, hasVideo: false)
        project.assets = [asset]
        var clip = Clip(name: "音", start: 0, duration: 1.0,
                        content: .media(assetID: asset.id, sourceStart: 0))
        clip.fade = Fade(inDuration: 0.8, outDuration: 0.8)
        project.tracks[2].clips = [clip]

        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        #expect(built.audioMix != nil)
    }

    @Test("幅・高さ・fps が 0 以下のキャンバスは組み立てで弾く")
    func invalidCanvasThrowsBuildError() async {
        for canvas in [
            CanvasSpec(width: 0, height: 180, fps: 30),
            CanvasSpec(width: 320, height: 0, fps: 30),
            CanvasSpec(width: 320, height: 180, fps: 0),
            CanvasSpec(width: 320, height: 180, fps: -30),
        ] {
            var project = textProject()
            project.canvas = canvas
            await #expect(throws: BuildError.self) {
                _ = try await CompositionBuilder.build(project: project, baseURL: nil)
            }
        }
    }
}

/// 動画の回転メタデータ（preferredTransform）と静止画の EXIF Orientation の向き。
struct MediaOrientationTests {

    /// 左上=赤、右上=緑、左下=青、右下=黄 の 4 色 CVPixelBuffer（横長 160x80）。
    private func quadrantPixelBuffer(width: Int = 160, height: Int = 80) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey as String: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary,
            &buffer)
        try #require(status == kCVReturnSuccess)
        let pb = try #require(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let top = y < height / 2
                let left = x < width / 2
                // BGRA
                let (r, g, b): (UInt8, UInt8, UInt8) = switch (top, left) {
                case (true, true): (230, 30, 30)      // 左上: 赤
                case (true, false): (30, 210, 30)     // 右上: 緑
                case (false, true): (30, 60, 230)     // 左下: 青
                case (false, false): (230, 210, 30)   // 右下: 黄
                }
                let i = y * bpr + x * 4
                base[i] = b; base[i + 1] = g; base[i + 2] = r; base[i + 3] = 255
            }
        }
        return pb
    }

    private func label(of c: (r: Int, g: Int, b: Int, a: Int)) -> String {
        if c.r > 180 && c.g < 100 && c.b < 100 { return "R" }
        if c.r < 100 && c.g > 150 && c.b < 100 { return "G" }
        if c.r < 100 && c.g < 120 && c.b > 170 { return "B" }
        if c.r > 180 && c.g > 160 && c.b < 100 { return "Y" }
        return "(\(c.r),\(c.g),\(c.b))"
    }

    @Test("preferredTransform（90° CW / 90° CCW / 180°）が正しい向きに合成される")
    func preferredTransformOrientsVideoCorrectly() throws {
        let pb = try quadrantPixelBuffer(width: 160, height: 80)
        let compositor = NanovidCompositor()
        let cases: [(name: String, preferred: CGAffineTransform, expected: [String])] = [
            // 90° CW（iPhone 縦撮り）: 左下(B)→左上, 左上(R)→右上, 右下(Y)→左下, 右上(G)→右下
            ("90CW", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0), ["B", "R", "Y", "G"]),
            // 90° CCW: 右上(G)→左上, 右下(Y)→右上, 左上(R)→左下, 左下(B)→右下
            ("90CCW", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 160), ["G", "Y", "R", "B"]),
            // 180°: 右下(Y)→左上, 左下(B)→右上, 右上(G)→左下, 左上(R)→右下
            ("180", CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 160, ty: 80), ["Y", "B", "G", "R"]),
        ]
        for item in cases {
            let layer = RenderLayer(
                source: .media(trackID: 1, preferredTransform: item.preferred),
                clipStart: 0, clipDuration: 1, transform: .identity, opacity: 1, fade: .none)
            let inst = NanovidInstruction(
                timeRange: CMTimeRange(start: .zero, duration: 1.0.cmTime),
                layers: [layer], backgroundColor: .black,
                canvasSize: CGSize(width: 160, height: 160), alwaysRenders: true)
            let cg = try #require(compositor.render(instruction: inst, at: 0.5) { _ in pb })
            let frame = try #require(RGBAFrame(cg))
            let pts: [(Double, Double)] = item.name == "180"
                ? [(0.25, 0.35), (0.75, 0.35), (0.25, 0.65), (0.75, 0.65)]
                : [(0.35, 0.25), (0.65, 0.25), (0.35, 0.75), (0.65, 0.75)]
            let actual = pts.map { label(of: frame.color(atX: $0.0, y: $0.1)) }
            #expect(actual == item.expected, "\(item.name): 期待 \(item.expected) に対して \(actual)")
        }
    }

    @Test("EXIF Orientation 付きの静止画は正立サイズと向きで読み込まれる")
    func exifOrientationIsAppliedOnLoadAndProbe() throws {
        // 生ピクセル 160x80: 左半分=赤、右半分=青
        let ctx = try #require(CGContext(
            data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 80, y: 0, width: 80, height: 80))
        let raw = try #require(ctx.makeImage())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanovid-exif6-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        // Orientation 6 = 90° CW → 縦長 80x160、上が赤・下が青になるはず
        CGImageDestinationAddImage(dest, raw, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let probed = try #require(ImageProbe.size(of: url))
        #expect(probed == CGSize(width: 80, height: 160))

        let loaded = try #require(CompositionBuilder.loadImage(url))
        #expect(loaded.width == 80)
        #expect(loaded.height == 160)
        let frame = try #require(RGBAFrame(loaded))
        #expect(label(of: frame.color(atX: 0.5, y: 0.2)) == "R")
        #expect(label(of: frame.color(atX: 0.5, y: 0.8)) == "B")
    }
}
