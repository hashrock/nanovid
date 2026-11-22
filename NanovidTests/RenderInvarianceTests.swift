import Testing
import Foundation
import CoreGraphics
@testable import Nanovid

/// 「こう変えても絵は変わらないはず」を、実際に描いて確かめる。
///
/// 正解の画像は持たない。同じプロジェクトを、見た目に効かないはずの操作の
/// 前後で描き比べる。macOS の版で文字の描かれ方が少し変わっても、両方が
/// 同じだけ変わるので落ちない。
///
/// ここにある性質は、どれも実際に壊れていたもの（ロックで消える、複製で背景板が
/// 追従しない、prop の key 変更で文字が消える、はみ出した文字が欠ける）。
@Suite(.tags(.render), TestTier.heavy)
@MainActor
struct RenderInvarianceTests {

    // MARK: - プロジェクト

    /// 文字を何枚も重ねた小さなプロジェクト。テンプレートは同梱の 4 種を混ぜ、
    /// 移動・拡大・回転・不透明度・フェードもばらつかせる。下に映像も敷く。
    private func makeProject(seed: UInt64) throws -> Project {
        let blank = try #require(Bundle.main.url(forResource: "blank", withExtension: "mp4"))
        var g = SeededGenerator(seed: seed)
        var project = Project.starter()
        project.canvas = CanvasSpec(width: 320, height: 180, fps: 30)
        project.canvas.backgroundColor = RGBAColor(hex: "#203040")!
        let asset = MediaAsset(path: blank.path, displayName: "素材", kind: .video,
                               duration: 60, naturalSize: CGSize(width: 16, height: 16),
                               hasAudio: false, hasVideo: true)
        project.assets = [asset]
        project.tracks[0].clips = [Clip(name: "下地", start: 0, duration: 6,
                                        content: .media(assetID: asset.id, sourceStart: 0))]
        project.tracks.insert(Track(name: "テロップ 2", kind: .video), at: 2)

        let words = ["こんにちは", "Hello", "長めの字幕を一行に入れてみる", "改行\nあり", "42"]
        for ti in [1, 2] {
            var cursor = 0.0
            for i in 0..<g.int(in: 2...3) {
                let template = g.pick(project.textTemplates)
                let duration = g.double(in: 0.6...1.8)
                var props: [String: PropValue] = [:]
                for def in template.props where def.type == .string && g.chance(0.8) {
                    props[def.key] = .string(g.pick(words))
                }
                var clip = Clip(name: "t\(ti)-\(i)", start: cursor + g.double(in: 0...0.3),
                                duration: duration,
                                content: .text(TextInstance(templateID: template.id, props: props)))
                if g.chance(0.6) {
                    clip.transform = Transform2D(
                        position: CGPoint(x: g.double(in: -0.2...0.2), y: g.double(in: -0.3...0.1)),
                        scale: g.double(in: 0.6...1.4),
                        rotation: g.chance(0.3) ? g.double(in: -0.4...0.4) : 0)
                }
                clip.opacity = g.chance(0.3) ? g.double(in: 0.4...1) : 1
                if g.chance(0.4) { clip.fade = Fade(inDuration: 0.2, outDuration: 0.2) }
                project.tracks[ti].clips.append(clip)
                cursor = clip.end
            }
        }
        return project
    }

    /// 区間ごとの真ん中で両方を描き、絵が同じかを確かめる。
    private func expectSamePictures(_ a: Project, _ b: Project, seed: Int, _ what: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let ra = try await HeadlessRender.renderer(for: a)
        let rb = try await HeadlessRender.renderer(for: b)
        let times = ra.renderer.segmentMidpoints()
        try #require(!times.isEmpty, sourceLocation: sourceLocation)
        for t in times {
            guard let fa = ra.frame(at: t), let fb = rb.frame(at: t) else {
                Issue.record("seed \(seed): \(what) \(t) 秒を描けない", sourceLocation: sourceLocation)
                continue
            }
            let changed = fa.changedFraction(from: fb)
            #expect(changed == 0, """
                seed \(seed): \(what)で \(String(format: "%.3f", t)) 秒の絵が変わった\
                （\(String(format: "%.3f", changed * 100))% の画素）
                """, sourceLocation: sourceLocation)
        }
    }

    // MARK: - 性質

    @Test("トラックをロックしても絵は変わらない", arguments: PropertyRuns.seeds(16))
    func lockingKeepsThePicture(seed: Int) async throws {
        let project = try makeProject(seed: UInt64(seed))
        var locked = project
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x10CC)
        for i in locked.tracks.indices where g.chance(0.6) { locked.tracks[i].isLocked = true }
        try await expectSamePictures(project, locked, seed: seed, "ロック")
    }

    @Test("テンプレートを複製して差し替えても絵は変わらない", arguments: PropertyRuns.seeds(16))
    func duplicatedTemplateLooksTheSame(seed: Int) async throws {
        let project = try makeProject(seed: UInt64(seed))
        var swapped = project
        var replacement: [UUID: UUID] = [:]
        for template in project.textTemplates {
            let copy = template.duplicated(name: template.name)
            swapped.textTemplates.append(copy)
            replacement[template.id] = copy.id
        }
        for ti in swapped.tracks.indices {
            for ci in swapped.tracks[ti].clips.indices {
                guard case .text(var inst) = swapped.tracks[ti].clips[ci].content,
                      let to = replacement[inst.templateID] else { continue }
                inst.templateID = to
                swapped.tracks[ti].clips[ci].content = .text(inst)
            }
        }
        try await expectSamePictures(project, swapped, seed: seed, "複製")
    }

    @Test("prop の key を変えて保存しても絵は変わらない", arguments: PropertyRuns.seeds(16))
    func renamingPropsKeepsThePicture(seed: Int) async throws {
        let project = try makeProject(seed: UInt64(seed))
        let store = EditorStore(project: project)
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x4E4E)
        for template in project.textTemplates {
            var edited = template
            // 全部の key を変える。入れ替え（a→b, b→a）も混ぜる。
            let keys = edited.props.map(\.key)
            let shuffled = g.chance(0.5) ? keys.shuffled(using: &g) : keys.map { $0 + "_renamed" }
            for i in edited.props.indices { edited.props[i].key = shuffled[i] }
            store.upsertTemplate(edited)
        }
        try await expectSamePictures(project, store.project, seed: seed, "key の変更")
    }

    @Test("テンプレートで外へ出した文字を、クリップの移動で戻すと元と同じ絵になる",
          arguments: PropertyRuns.seeds(16))
    func movingTextBackInLooksTheSame(seed: Int) async throws {
        var project = try makeProject(seed: UInt64(seed))
        // 回転があると、ずらした量まで回ってしまい「同じだけ戻す」が成り立たない。
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices { project.tracks[ti].clips[ci].transform.rotation = 0 }
        }
        var moved = project
        // キャンバス 1 枚ぶん下へ出す。画素ちょうどのずれにしておくと、戻した絵が画素まで一致する。
        moved.textTemplates = moved.textTemplates.map { template in
            var t = template
            t.nodes = t.nodes.map { var n = $0; n.frame.y += 1; return n }
            return t
        }
        for ti in moved.tracks.indices {
            for ci in moved.tracks[ti].clips.indices
            where moved.tracks[ti].clips[ci].content.textInstance != nil {
                // 拡大の中心はキャンバスの中心なので、拡大率ぶん戻す量も伸びる。
                let scale = moved.tracks[ti].clips[ci].transform.scale
                moved.tracks[ti].clips[ci].transform.position.y -= scale
            }
        }
        try await expectSamePictures(project, moved, seed: seed, "外へ出して戻す")
    }

    // MARK: - 自前の合成と AVFoundation の経路

    @Test("文字だけなら、自前の合成と AVFoundation の経路で同じ絵になる",
          arguments: PropertyRuns.seeds(8))
    func directAndPlayerAgree(seed: Int) async throws {
        var project = try makeProject(seed: UInt64(seed))
        // 素材は direct では単色の代用になるので、比べるのは文字だけにする。
        project.tracks[0].clips = []
        let renderer = try await FrameRenderer.make(project: project, baseURL: nil)
        for t in renderer.segmentMidpoints() {
            let direct = try #require(RGBAFrame(try renderer.renderDirect(at: t)))
            let player = try #require(RGBAFrame(try await renderer.renderPlayer(at: t)))
            let changed = direct.changedFraction(from: player)
            #expect(changed <= 0.002, """
                seed \(seed): \(String(format: "%.3f", t)) 秒で 2 つの経路の絵が違う\
                （\(String(format: "%.3f", changed * 100))% の画素）
                """)
        }
    }
}

/// `--render` の引数の読み取り。
struct RenderCommandTests {

    @Test("--render が無ければ何もしない")
    func ignoresOtherLaunches() throws {
        #expect(try RenderCommand.parse(["Nanovid", "--inspect", "a.nanovid"]) == nil)
    }

    @Test("時刻・出力先・描き方・素材・許容を読む")
    func parsesOptions() throws {
        let o = try #require(try RenderCommand.parse([
            "Nanovid", "--render", "/tmp/a.nanovid", "--at", "0.5, 1.5,3",
            "--out", "/tmp/out", "--path", "player", "--sources", "stub", "--tolerance", "0.01",
            "-NSDocumentRevisionsDebugMode", "YES",
        ]))
        #expect(o.project.path == "/tmp/a.nanovid")
        #expect(o.times == [0.5, 1.5, 3])
        #expect(o.out.path == "/tmp/out")
        #expect(o.paths == [.player])
        #expect(o.sources == .stub)
        #expect(o.tolerance == 0.01)
    }

    @Test("既定は両方の経路で描き、本物の素材を使う")
    func defaults() throws {
        let o = try #require(try RenderCommand.parse(["Nanovid", "--render", "a.nanovid"]))
        #expect(o.times == nil)
        #expect(o.paths == FrameRenderer.Path.allCases)
        #expect(o.sources == .decoded)
    }

    @Test("おかしな値ははっきり断る")
    func rejectsBadValues() {
        #expect(throws: RenderCommand.UsageError.self) {
            try RenderCommand.parse(["Nanovid", "--render"])
        }
        #expect(throws: RenderCommand.UsageError.self) {
            try RenderCommand.parse(["Nanovid", "--render", "a.nanovid", "--at", "x"])
        }
        #expect(throws: RenderCommand.UsageError.self) {
            try RenderCommand.parse(["Nanovid", "--render", "a.nanovid", "--path", "gpu"])
        }
    }
}
