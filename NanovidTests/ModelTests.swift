import Testing
import Foundation
@testable import Nanovid

struct FadeTests {

    @Test("フェードなしでは常に 1")
    func noFade() {
        let fade = Fade.none
        #expect(fade.factor(at: 0, clipDuration: 5) == 1)
        #expect(fade.factor(at: 2.5, clipDuration: 5) == 1)
    }

    @Test("イン・アウトの両端が 0 で中央が 1")
    func inAndOut() {
        let fade = Fade(inDuration: 1, outDuration: 1)
        #expect(abs(fade.factor(at: 0, clipDuration: 5) - 0) < 1e-9)
        #expect(abs(fade.factor(at: 0.5, clipDuration: 5) - 0.5) < 1e-9)
        #expect(abs(fade.factor(at: 2.5, clipDuration: 5) - 1) < 1e-9)
        #expect(abs(fade.factor(at: 4.5, clipDuration: 5) - 0.5) < 1e-9)
        #expect(abs(fade.factor(at: 5, clipDuration: 5) - 0) < 1e-9)
    }

    @Test("イン・アウトが重なっても 0...1 に収まる")
    func overlappingFadesStayInRange() {
        let fade = Fade(inDuration: 4, outDuration: 4)
        for t in stride(from: 0.0, through: 5.0, by: 0.1) {
            let f = fade.factor(at: t, clipDuration: 5)
            #expect(f >= 0 && f <= 1)
        }
    }

    @Test("クリップの実効不透明度と音量にフェードが乗る")
    func clipAppliesFade() {
        var clip = Clip(start: 10, duration: 4, content: .text(TextInstance(templateID: UUID())))
        clip.opacity = 0.5
        clip.volume = 0.8
        clip.fade = Fade(inDuration: 2, outDuration: 0)
        #expect(abs(clip.effectiveOpacity(at: 11) - 0.25) < 1e-9)
        #expect(abs(clip.effectiveVolume(at: 11) - 0.4) < 1e-9)
        #expect(abs(clip.effectiveOpacity(at: 13) - 0.5) < 1e-9)
    }
}

struct CanvasSpecTests {

    @Test("フレーム境界に丸める")
    func snapsToFrames() {
        let canvas = CanvasSpec(width: 1920, height: 1080, fps: 30)
        #expect(abs(canvas.snap(0.51) - 0.5) < 1e-9)
        #expect(abs(canvas.snap(0.49) - 0.5) < 1e-9)
        #expect(abs(canvas.snap(1.0 / 30 * 0.4) - 0) < 1e-9)
    }

    @Test("解像度プリセットの縦横比")
    func aspectRatios() {
        #expect(abs(CanvasSpec(width: 1920, height: 1080, fps: 30).aspectRatio - 16.0 / 9) < 1e-9)
        #expect(abs(CanvasSpec(width: 1080, height: 1920, fps: 30).aspectRatio - 9.0 / 16) < 1e-9)
    }

    @Test("YouTube HD と Short が用意されている")
    func presetsExist() {
        let sizes = CanvasPreset.all.map(\.size)
        #expect(sizes.contains(CGSize(width: 1920, height: 1080)))
        #expect(sizes.contains(CGSize(width: 1080, height: 1920)))
    }
}

struct ColorTests {

    @Test("16 進表記の往復")
    func hexRoundTrip() {
        let c = RGBAColor(hex: "#4FC3F7")!
        #expect(c.hexString == "#4FC3F7")
        let withAlpha = RGBAColor(hex: "#1E88E5CC")!
        #expect(withAlpha.hexString == "#1E88E5CC")
        #expect(abs(withAlpha.a - 204.0 / 255) < 1e-9)
    }

    @Test("不正な文字列は nil")
    func invalidHex() {
        #expect(RGBAColor(hex: "ほげ") == nil)
        #expect(RGBAColor(hex: "#12345") == nil)
    }
}

struct TextTemplateTests {

    @Test("インスタンスは指定した props だけを上書きする")
    func propsOverrideDefaultsOnly() {
        let template = TextTemplate.subtitle()
        var instance = TextInstance(templateID: template.id)
        instance.props["text"] = .string("上書き")

        let resolved = instance.resolvedProps(in: template)
        #expect(resolved["text"]?.stringValue == "上書き")
        // 触っていない項目はテンプレートの既定値のまま
        #expect(resolved["textColor"]?.colorValue == RGBAColor.white)
        #expect(instance.props["textColor"] == nil, "上書きしていない項目は保持しない")
    }

    @Test("ValueRef は固定値と props バインドを切り替えられる")
    func valueRefResolution() {
        let defaults: [String: PropValue] = ["c": .color(.white)]
        let literal = ValueRef.literal(.string("固定"))
        #expect(literal.resolve([:], defaults: defaults)?.stringValue == "固定")
        #expect(literal.boundKey == nil)

        let bound = ValueRef.prop("c")
        #expect(bound.boundKey == "c")
        #expect(bound.resolve([:], defaults: defaults)?.colorValue == RGBAColor.white)
        #expect(bound.resolve(["c": .color(.black)], defaults: defaults)?.colorValue == RGBAColor.black)
    }

    @Test("相対フレームは解像度が変わってもレイアウトが保たれる")
    func relFrameScalesWithCanvas() {
        let frame = RelFrame(x: 0.5, y: 0.9, width: 0.8, height: 0.1, anchor: .bottom)
        let hd = frame.rect(in: CGSize(width: 1920, height: 1080))
        let short = frame.rect(in: CGSize(width: 1080, height: 1920))

        // 中央寄せの関係が両方で保たれている
        #expect(abs(hd.midX / 1920 - 0.5) < 1e-9)
        #expect(abs(short.midX / 1080 - 0.5) < 1e-9)
        #expect(abs(hd.maxY / 1080 - 0.9) < 1e-9)
        #expect(abs(short.maxY / 1920 - 0.9) < 1e-9)
    }

    @Test("同梱テンプレートが一通りそろっている")
    func builtinTemplates() {
        let names = Project.starter().textTemplates.map(\.name)
        #expect(names.contains("字幕"))
        #expect(names.contains("シンプル字幕"))
        #expect(names.contains("テロップ（左下）"))
        #expect(names.contains("タイトル"))
        #expect(Set(names).count == names.count, "名前が重複している")
    }

    @Test("シンプル字幕は背景板を持たず縁取りで読ませる")
    func plainSubtitleUsesStroke() {
        let template = TextTemplate.plainSubtitle()
        let hasRect = template.nodes.contains { if case .rect = $0.kind { return true }; return false }
        #expect(!hasRect)

        guard case .text(let spec) = template.nodes[0].kind else {
            Issue.record("テキストノードであるべき")
            return
        }
        #expect(spec.strokeWidth > 0)
        #expect(spec.strokeColor.boundKey == "strokeColor")
        #expect(template.props.contains { $0.key == "strokeColor" })
    }

    @Test("同梱テンプレートの props バインドが定義と食い違わない")
    func builtinBindingsResolve() {
        for template in Project.starter().textTemplates {
            let keys = Set(template.props.map(\.key))
            for node in template.nodes {
                var refs: [ValueRef] = []
                switch node.kind {
                case .text(let spec):
                    refs = [spec.text, spec.color, spec.strokeColor, spec.shadowColor]
                case .rect(let spec):
                    refs = [spec.fill]
                }
                for ref in refs {
                    if let key = ref.boundKey {
                        #expect(keys.contains(key),
                                "\(template.name) の \(node.name) が未定義の props.\(key) を参照している")
                    }
                }
            }
        }
    }

    @Test("テンプレートを使っているクリップを引ける")
    func findsClipsUsingTemplate() {
        var project = Project.starter()
        let template = project.textTemplates[0]
        project.tracks[1].clips = [
            Clip(start: 0, duration: 1, content: .text(TextInstance(templateID: template.id))),
            Clip(start: 2, duration: 1, content: .text(TextInstance(templateID: template.id))),
            Clip(start: 4, duration: 1, content: .text(TextInstance(templateID: project.textTemplates[1].id))),
        ]
        #expect(project.textClips(usingTemplate: template.id).count == 2)
        #expect(project.allTextClips.count == 3)
    }
}
