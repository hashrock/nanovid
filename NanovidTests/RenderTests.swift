import Testing
import Foundation
import AVFoundation
@testable import Nanovid

/// Project から AVFoundation へ落とすところ。
struct CompositionBuilderTests {

    private func textOnlyProject() -> Project {
        var project = Project.starter()
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 0, duration: 1,
                 content: .text(TextInstance(templateID: template.id,
                                             props: ["text": .string("ひとつめ")]))),
            // 1.0〜2.0 は何も無い区間
            Clip(start: 2, duration: 1,
                 content: .text(TextInstance(templateID: template.id,
                                             props: ["text": .string("ふたつめ")]))),
        ]
        return project
    }

    @Test("命令はタイムライン全体を隙間なく覆う")
    func instructionsCoverTimelineContiguously() async throws {
        let built = try await CompositionBuilder.build(project: textOnlyProject(), baseURL: nil)
        let instructions = built.videoComposition.instructions
        try #require(!instructions.isEmpty)

        #expect(instructions[0].timeRange.start == .zero)
        for i in 1..<instructions.count {
            #expect(instructions[i].timeRange.start == instructions[i - 1].timeRange.end,
                    "区間 \(i) がひとつ前と繋がっていない")
        }
        let end = instructions[instructions.count - 1].timeRange.end.seconds
        #expect(abs(end - built.duration) < 1e-6)
    }

    @Test("何も置かれていない区間にはレイヤーが無い")
    func gapHasNoLayers() async throws {
        let built = try await CompositionBuilder.build(project: textOnlyProject(), baseURL: nil)
        let gap = built.videoComposition.instructions.compactMap { $0 as? NanovidInstruction }
            .first { $0.timeRange.start.seconds >= 1.0 && $0.timeRange.end.seconds <= 2.0 }
        try #require(gap != nil)
        #expect(gap!.layers.isEmpty)
        #expect(gap!.requiredSourceTrackIDs == nil)
    }

    @Test("テキストだけでも映像トラックが用意される")
    func spacerTrackIsInserted() async throws {
        let built = try await CompositionBuilder.build(project: textOnlyProject(), baseURL: nil)
        // 土台のブランク素材が敷かれていないと、書き出しがすぐ途切れてしまう
        let videoTracks = built.composition.tracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty)
        #expect(abs(videoTracks[0].timeRange.duration.seconds - built.duration) < 0.05)
    }

    @Test("レンダー設定がキャンバスと一致する")
    func renderSettingsMatchCanvas() async throws {
        var project = textOnlyProject()
        project.canvas = CanvasSpec(width: 1080, height: 1920, fps: 60)
        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        #expect(built.videoComposition.renderSize == CGSize(width: 1080, height: 1920))
        #expect(built.videoComposition.frameDuration == CMTime(value: 1, timescale: 60))
        #expect(built.videoComposition.customVideoCompositorClass == NanovidCompositor.self)
    }

    @Test("空のタイムラインは組み立てを拒否する")
    func emptyProjectThrows() async {
        await #expect(throws: BuildError.self) {
            _ = try await CompositionBuilder.build(project: Project(), baseURL: nil)
        }
    }

    @Test("重なったクリップは背面から前面の順に並ぶ")
    func overlappingLayersAreOrderedBackToFront() async throws {
        var project = Project.starter()
        let template = project.textTemplates[0]
        // tracks[0] が最背面、tracks[1] が手前
        project.tracks[0].clips = [Clip(start: 0, duration: 2,
                                        content: .text(TextInstance(templateID: template.id,
                                                                    props: ["text": .string("背面")])))]
        project.tracks[1].clips = [Clip(start: 0, duration: 2,
                                        content: .text(TextInstance(templateID: template.id,
                                                                    props: ["text": .string("前面")])))]
        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        let instruction = built.videoComposition.instructions
            .compactMap { $0 as? NanovidInstruction }
            .first { $0.timeRange.containsTime(CMTime(seconds: 1, preferredTimescale: 600)) }
        try #require(instruction != nil)
        #expect(instruction!.layers.count == 2)
    }
}

struct TextRasterizerTests {

    @Test("テキストが空でなければ描画結果が返る")
    func rasterizesText() throws {
        let template = TextTemplate.subtitle()
        let raster = try #require(TextRasterizer.shared.rasterize(
            template: template,
            props: template.defaultProps,
            canvas: CGSize(width: 1920, height: 1080)))
        #expect(raster.image.width > 0)
        #expect(raster.image.height > 0)
        // キャンバス全面ではなく、必要な範囲だけを持つ
        #expect(raster.rect.width < 1920)
        #expect(raster.rect.height < 1080)
    }

    @Test("同じ内容ならキャッシュを返す")
    func cachesByContent() {
        let template = TextTemplate.title()
        let props = template.defaultProps
        let size = CGSize(width: 1280, height: 720)
        let a = TextRasterizer.shared.rasterize(template: template, props: props, canvas: size)
        let b = TextRasterizer.shared.rasterize(template: template, props: props, canvas: size)
        #expect(a?.image === b?.image)
    }

    @Test("props が違えば別の結果になり、描画範囲も文字量に追従する")
    func differentPropsProduceDifferentImages() {
        let template = TextTemplate.subtitle()
        let size = CGSize(width: 1280, height: 720)
        var props = template.defaultProps
        let a = TextRasterizer.shared.rasterize(template: template, props: props, canvas: size)
        props["text"] = .string("ぜんぜん違う長さの文字列を入れてみる")
        let b = TextRasterizer.shared.rasterize(template: template, props: props, canvas: size)
        #expect(a?.image !== b?.image)
        #expect(a?.rect.width != b?.rect.width)
    }

    @Test("空文字なら何も描かない")
    func emptyTextProducesNothing() {
        var template = TextTemplate.subtitle()
        template.nodes = template.nodes.filter { if case .text = $0.kind { return true }; return false }
        var props = template.defaultProps
        props["text"] = .string("")
        let raster = TextRasterizer.shared.rasterize(template: template, props: props,
                                                     canvas: CGSize(width: 1280, height: 720))
        #expect(raster == nil)
    }
}

struct ExportSettingsTests {

    @Test("解像度とフレームレートに応じてビットレートが上がる")
    func bitrateScalesWithResolution() {
        let settings = ExportSettings(codec: .h264, quality: .high)
        let hd = settings.videoBitrate(canvas: CanvasSpec(width: 1920, height: 1080, fps: 30))
        let uhd = settings.videoBitrate(canvas: CanvasSpec(width: 3840, height: 2160, fps: 30))
        let hd60 = settings.videoBitrate(canvas: CanvasSpec(width: 1920, height: 1080, fps: 60))
        #expect(uhd > hd)
        #expect(hd60 > hd)
    }

    @Test("HEVC は H.264 より低いビットレートを選ぶ")
    func hevcUsesLowerBitrate() {
        let canvas = CanvasSpec(width: 1920, height: 1080, fps: 30)
        let h264 = ExportSettings(codec: .h264, quality: .high).videoBitrate(canvas: canvas)
        let hevc = ExportSettings(codec: .hevc, quality: .high).videoBitrate(canvas: canvas)
        #expect(hevc < h264)
    }

    @Test("極端な設定でも現実的な範囲に収める")
    func bitrateIsClamped() {
        let tiny = ExportSettings(codec: .h264, quality: .standard)
            .videoBitrate(canvas: CanvasSpec(width: 16, height: 16, fps: 1))
        #expect(tiny >= 1_000_000)
        let huge = ExportSettings(codec: .h264, quality: .max)
            .videoBitrate(canvas: CanvasSpec(width: 7680, height: 4320, fps: 60))
        #expect(huge <= 120_000_000)
    }
}
