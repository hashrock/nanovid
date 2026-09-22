import Testing
import Foundation
import CoreGraphics
@testable import Nanovid

/// 実際に描いた絵で確かめる。再生も書き出しも通さない。
@MainActor
struct HeadlessRenderTests {

    /// 640x360、背景は濃い灰色。素材は 1 本だけ持たせる。
    ///
    /// 素材の実体は同梱の blank.mp4 を借りる。組み立てはファイルの実在を確かめるので、
    /// 存在しないパスだと組む前に弾かれてしまう。描く中身のほうは
    /// HeadlessRender が単色で差し替えるので、元の画は使わない。
    private func makeProject() throws -> Project {
        let blank = try #require(Bundle.main.url(forResource: "blank", withExtension: "mp4"),
                                 "同梱の blank.mp4 が見つかりません")
        var project = Project.starter()
        project.canvas = CanvasSpec(width: 640, height: 360, fps: 30)
        project.canvas.backgroundColor = RGBAColor(hex: "#202020")!
        project.assets = [
            MediaAsset(path: blank.path, displayName: "素材",
                       kind: .video, duration: 60, naturalSize: CGSize(width: 16, height: 16),
                       hasAudio: false, hasVideo: true),
        ]
        project.tracks[0].clips = []
        project.tracks[1].clips = []
        return project
    }

    private func mediaClip(start: Double, duration: Double) -> Clip {
        Clip(name: "素材", start: start, duration: duration,
             content: .media(assetID: UUID(), sourceStart: 0))
    }

    @Test("何も置いていない時刻は背景色で埋まる")
    func emptyTimeShowsTheBackground() async throws {
        var project = try makeProject()
        project.tracks[1].clips = [Clip(name: "字幕", start: 2, duration: 1,
                                        content: .text(TextInstance(
                                            templateID: project.textTemplates[0].id,
                                            props: ["text": .string("あとから出る")])))]
        let frame = try #require(try await HeadlessRender.frame(of: project, at: 0.5))
        let c = frame.color(atX: 0.5, y: 0.5)
        #expect(abs(c.r - 0x20) <= 2 && abs(c.g - 0x20) <= 2 && abs(c.b - 0x20) <= 2,
                "背景色 #202020 のはずが \(c)")
    }

    @Test("フェードの途中は背景に溶けていく")
    func fadeBlendsTowardTheBackground() async throws {
        var project = try makeProject()
        var clip = mediaClip(start: 0, duration: 4)
        if let asset = project.assets.first {
            clip.content = .media(assetID: asset.id, sourceStart: 0)
        }
        clip.fade = Fade(inDuration: 2, outDuration: 0)
        project.tracks[0].clips = [clip]

        // 素材は単色で代用される。時刻が進むほど背景から離れていく。
        var distances: [Double] = []
        for t in [0.2, 1.0, 1.8] {
            let frame = try #require(try await HeadlessRender.frame(of: project, at: t))
            let c = frame.color(atX: 0.5, y: 0.5)
            distances.append(Double(abs(c.r - 0x20) + abs(c.g - 0x20) + abs(c.b - 0x20)))
        }
        #expect(distances[0] < distances[1], "0.2 秒より 1.0 秒のほうが濃いはず \(distances)")
        #expect(distances[1] < distances[2], "1.0 秒より 1.8 秒のほうが濃いはず \(distances)")
    }

    @Test("フェードが終われば素材の色がそのまま出る")
    func fullyOpaqueAfterTheFade() async throws {
        var project = try makeProject()
        var clip = mediaClip(start: 0, duration: 4)
        clip.content = .media(assetID: project.assets[0].id, sourceStart: 0)
        clip.fade = Fade(inDuration: 1, outDuration: 0)
        project.tracks[0].clips = [clip]

        let frame = try #require(try await HeadlessRender.frame(of: project, at: 2.0))
        let c = frame.color(atX: 0.5, y: 0.5)
        #expect(c.r + c.g + c.b > 200, "素材の単色が出ているはずが \(c)")
    }

    @Test("縮めて置いた映像は指定した矩形の中だけに出る")
    func scaledMediaStaysInsideItsRect() async throws {
        var project = try makeProject()
        var clip = mediaClip(start: 0, duration: 2)
        clip.content = .media(assetID: project.assets[0].id, sourceStart: 0)
        clip.transform = Transform2D(position: .zero, scale: 0.5, rotation: 0)
        project.tracks[0].clips = [clip]

        let frame = try #require(try await HeadlessRender.frame(of: project, at: 1.0))
        let center = frame.color(atX: 0.5, y: 0.5)
        let corner = frame.color(atX: 0.05, y: 0.05)
        #expect(center.r + center.g + center.b > 200, "中央には素材が出るはずが \(center)")
        #expect(abs(corner.r - 0x20) <= 2 && abs(corner.g - 0x20) <= 2,
                "四隅は背景のままのはずが \(corner)")
    }

    @Test("前面のクリップが背面を覆う")
    func frontLayerCoversTheBack() async throws {
        var project = try makeProject()
        // tracks[0] が最背面、tracks[1] がその上。どちらも画面いっぱい。
        var back = mediaClip(start: 0, duration: 2)
        back.content = .media(assetID: project.assets[0].id, sourceStart: 0)
        var front = mediaClip(start: 0, duration: 2)
        front.content = .media(assetID: project.assets[0].id, sourceStart: 5)
        project.tracks[0].clips = [back]
        project.tracks[1].clips = [front]

        let frame = try #require(try await HeadlessRender.frame(of: project, at: 1.0))
        // 合成トラックごとに色を変えてあるので、前面に使われたほうの色が出る。
        let built = try await CompositionBuilder.build(project: project, baseURL: nil)
        let videoTracks = built.composition.tracks(withMediaType: .video)
        let ids = videoTracks.map(\.trackID).sorted()
        #expect(ids.count >= 2, "映像トラックが 2 本以上あるはず")

        let shown = frame.color(atX: 0.5, y: 0.5)
        let expected = HeadlessRender.stubColor(for: ids[1])   // 後に足したほうが前面
        #expect(abs(shown.r - Int(expected.r)) <= 4
                && abs(shown.g - Int(expected.g)) <= 4
                && abs(shown.b - Int(expected.b)) <= 4,
                "前面のトラック \(ids[1]) の色が出るはずが \(shown)")
    }

    @Test("透明度を下げると背景が透ける")
    func opacityLetsTheBackgroundThrough() async throws {
        var project = try makeProject()
        var clip = mediaClip(start: 0, duration: 2)
        clip.content = .media(assetID: project.assets[0].id, sourceStart: 0)
        project.tracks[0].clips = [clip]

        var faded = project
        faded.tracks[0].clips[0].opacity = 0.25

        let solid = try #require(try await HeadlessRender.frame(of: project, at: 1.0))
        let sheer = try #require(try await HeadlessRender.frame(of: faded, at: 1.0))
        func distanceFromBackground(_ f: HeadlessRender.Frame) -> Int {
            let c = f.color(atX: 0.5, y: 0.5)
            return abs(c.r - 0x20) + abs(c.g - 0x20) + abs(c.b - 0x20)
        }
        #expect(distanceFromBackground(sheer) < distanceFromBackground(solid),
                "不透明度を下げたほうが背景に近いはず")
    }
}

/// 書き出す範囲の切り出しを、実際に描いた絵で確かめる。
///
/// モデルの上での「見え方」は OutputRange の性質テストで見ている。
/// ここはその先、合成まで通した絵が本当に一致するかを見る。
@MainActor
struct CropRenderPropertyTests {

    /// フェードつきのクリップを並べたプロジェクト。範囲の端がフェードに
    /// かかる形を作らないと、切り詰めの不具合が画に出てこない。
    private func makeProject(seed: UInt64) throws -> Project {
        let blank = try #require(Bundle.main.url(forResource: "blank", withExtension: "mp4"))
        var generator = SeededGenerator(seed: seed)
        var project = Project.starter()
        project.canvas = CanvasSpec(width: 320, height: 180, fps: 30)
        project.canvas.backgroundColor = RGBAColor(hex: "#103040")!
        let asset = MediaAsset(path: blank.path, displayName: "素材", kind: .video,
                               duration: 60, naturalSize: CGSize(width: 16, height: 16),
                               hasAudio: false, hasVideo: true)
        project.assets = [asset]

        var cursor = 0.0
        for i in 0..<generator.int(in: 2...4) {
            let gap = generator.double(in: 0...0.5)
            let duration = generator.double(in: 0.8...2.5)
            var clip = Clip(name: "c\(i)", start: cursor + gap, duration: duration,
                            content: .media(assetID: asset.id,
                                            sourceStart: generator.double(in: 0...10)))
            clip.fade = Fade(inDuration: generator.double(in: 0...duration / 2),
                             outDuration: generator.double(in: 0...duration / 2))
            clip.opacity = generator.double(in: 0.4...1)
            project.tracks[0].clips.append(clip)
            cursor = clip.end
        }

        // 上の段にテキストも重ねる。
        var text = Clip(name: "字幕", start: generator.double(in: 0...cursor / 2),
                        duration: generator.double(in: 0.5...2),
                        content: .text(TextInstance(templateID: project.textTemplates[0].id,
                                                    props: ["text": .string("重ねた字幕")])))
        text.fade = Fade(inDuration: 0.3, outDuration: 0.3)
        project.tracks[1].clips = [text]
        return project
    }

    @Test("切り出しても範囲の中は同じ絵になる", arguments: 0..<24)
    func croppingKeepsThePicture(seed: Int) async throws {
        var generator = SeededGenerator(seed: UInt64(seed) &+ 0xD12E)
        var project = try makeProject(seed: UInt64(seed))
        let end = project.contentEnd
        try #require(end > 1.0)

        // 幅のある範囲だけを見る。ごく短い範囲は見る点が取れず、
        // 切り詰めの当たり外れが絵に出ないので意味が薄い。
        let start = generator.double(in: 0...(end - 0.5))
        let width = generator.double(in: 0.5...(end - start))
        project.outputRange = OutputRange(start: start, end: start + width)

        let cropped = project.croppedToOutputRange()
        let beforeRenderer = try await HeadlessRender.renderer(for: project)
        let afterRenderer = try await HeadlessRender.renderer(for: cropped)

        // 範囲の中を等間隔に見る。端はフレームに乗せてから少し内側へ寄せる。
        for i in 0...6 {
            let t = project.outputStart
                + (project.outputEnd - project.outputStart) * (Double(i) + 0.5) / 7
            guard let before = beforeRenderer.frame(at: t),
                  let after = afterRenderer.frame(at: t) else { continue }
            let diff = before.difference(from: after)
            #expect(diff < 0.5, """
                seed \(seed): \(String(format: "%.4f", t)) 秒の絵が違う（差 \(diff)）
                範囲 \(String(format: "%.4f〜%.4f", project.outputStart, project.outputEnd))
                """)
        }
    }
}
