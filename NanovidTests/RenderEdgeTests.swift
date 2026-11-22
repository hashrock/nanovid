import Testing
import Foundation
import CoreMedia
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
}
