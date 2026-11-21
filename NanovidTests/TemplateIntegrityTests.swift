import Testing
import Foundation
import CoreGraphics
@testable import Nanovid

/// テンプレートを複製・編集しても、文字や背景板の参照が切れないこと。
struct TemplateIntegrityTests {

    private func textNode(_ t: TextTemplate) -> TemplateNode? {
        t.nodes.first { if case .text = $0.kind { return true }; return false }
    }

    private func textSpec(_ t: TextTemplate) -> TextNodeSpec? {
        guard case .text(let spec) = textNode(t)?.kind else { return nil }
        return spec
    }

    private func plateSpec(_ t: TextTemplate) -> RectNodeSpec? {
        for node in t.nodes { if case .rect(let spec) = node.kind { return spec } }
        return nil
    }

    // MARK: 複製

    @Test("複製すると背景板の追従先も新しいノード ID へ付け替わる")
    func duplicateRemapsFitTarget() throws {
        let original = TextTemplate.subtitle()
        let copy = original.duplicated(name: "コピー")

        #expect(copy.id != original.id)
        #expect(Set(copy.nodes.map(\.id)).isDisjoint(with: original.nodes.map(\.id)))
        let target = try #require(plateSpec(copy)?.fitToNodeID)
        #expect(target == textNode(copy)?.id)
    }

    @Test("複製したテンプレートでも背景板が文字量に追従する")
    func duplicatePlateFollowsText() throws {
        let copy = TextTemplate.subtitle().duplicated(name: "コピー")
        let size = CGSize(width: 1280, height: 720)
        var props = copy.defaultProps
        props["text"] = .string("短い")
        let short = try #require(TextRasterizer.shared.rasterize(template: copy, props: props, canvas: size))
        props["text"] = .string("ずっと長い文字列にすると背景板も横に伸びるはず")
        let long = try #require(TextRasterizer.shared.rasterize(template: copy, props: props, canvas: size))
        #expect(short.rect.width < long.rect.width)
    }

    // MARK: props の変更

    @Test("prop の key を変えるとノードの参照とクリップの上書き値が付いてくる")
    func renameFollowsReferences() throws {
        let old = TextTemplate.subtitle()
        var new = old
        let i = try #require(new.props.firstIndex { $0.key == "text" })
        new.props[i].key = "body"

        let reconciled = new.reconcilingProps(from: old)
        #expect(textSpec(reconciled)?.text == .prop("body"))

        let instance = TextInstance(templateID: old.id, props: ["text": .string("上書き")])
        let migrated = instance.migrating(from: old, to: reconciled)
        #expect(migrated.props == ["body": .string("上書き")])
    }

    @Test("key を入れ替えても取り違えない")
    func swappedKeysStayPaired() throws {
        let old = TextTemplate.subtitle()
        var new = old
        let a = try #require(new.props.firstIndex { $0.key == "textColor" })
        let b = try #require(new.props.firstIndex { $0.key == "plateColor" })
        new.props[a].key = "plateColor"
        new.props[b].key = "textColor"

        let reconciled = new.reconcilingProps(from: old)
        #expect(textSpec(reconciled)?.color == .prop("plateColor"))
        #expect(plateSpec(reconciled)?.fill == .prop("textColor"))
    }

    @Test("参照されている prop を消すと、その既定値の固定値になって文字が残る")
    func removedPropBecomesLiteral() throws {
        let old = TextTemplate.subtitle()
        let def = try #require(old.propDef(for: "text"))
        var new = old
        new.props.removeAll { $0.key == "text" }

        let reconciled = new.reconcilingProps(from: old)
        #expect(textSpec(reconciled)?.text == .literal(def.defaultValue))

        let instance = TextInstance(templateID: old.id, props: ["text": .string("上書き")])
        #expect(instance.migrating(from: old, to: reconciled).props.isEmpty)

        let raster = TextRasterizer.shared.rasterize(
            template: reconciled, props: reconciled.defaultProps,
            canvas: CGSize(width: 1280, height: 720))
        #expect(raster != nil)
    }

    @Test("型が変わって合わなくなった上書き値は捨てる")
    func typeChangeDropsMismatchedOverrides() throws {
        let old = TextTemplate.subtitle()
        var new = old
        let i = try #require(new.props.firstIndex { $0.key == "text" })
        new.props[i].type = .number
        new.props[i].defaultValue = .number(3)

        let instance = TextInstance(templateID: old.id, props: ["text": .string("上書き")])
        #expect(instance.migrating(from: old, to: new).props.isEmpty)
    }

    @Test("文字に数値の prop を当てても空にならず、数値が文字として出る")
    func numberPropRendersAsText() throws {
        var template = TextTemplate.subtitle()
        let i = try #require(template.props.firstIndex { $0.key == "text" })
        template.props[i].type = .number
        template.props[i].defaultValue = .number(42)
        let raster = TextRasterizer.shared.rasterize(
            template: template, props: template.defaultProps,
            canvas: CGSize(width: 1280, height: 720))
        #expect(raster != nil)
    }

    @Test("編集中に key が重なっても既定値の辞書を作るときに落ちない")
    func duplicateKeysDoNotCrash() throws {
        var template = TextTemplate.subtitle()
        let i = try #require(template.props.firstIndex { $0.key == "textColor" })
        template.props[i].key = "text"
        #expect(template.defaultProps["text"] != nil)
    }

    // MARK: ストア経由

    @Test("保存すると、そのテンプレートを使う全クリップの上書き値が付け替わる")
    @MainActor
    func upsertMigratesClips() throws {
        var project = Project.starter()
        let template = try #require(project.textTemplates.first { $0.propDef(for: "text") != nil })
        project.tracks[0].clips = [Clip(name: "字幕", start: 0, duration: 1,
                                        content: .text(TextInstance(
                                            templateID: template.id,
                                            props: ["text": .string("上書き")])))]
        let store = EditorStore(project: project)

        var edited = template
        let i = try #require(edited.props.firstIndex { $0.key == "text" })
        edited.props[i].key = "body"
        store.upsertTemplate(edited)

        let saved = try #require(store.project.template(template.id))
        let clip = try #require(store.project.tracks[0].clips.first)
        let instance = try #require(clip.content.textInstance)
        #expect(instance.props == ["body": .string("上書き")])
        #expect(instance.resolvedProps(in: saved)["body"] == .string("上書き"))
    }

    @Test("ストアの複製でも背景板の追従先が付け替わる")
    @MainActor
    func storeDuplicateRemapsFitTarget() throws {
        var project = Project.starter()
        project.textTemplates = [TextTemplate.subtitle()]
        let store = EditorStore(project: project)
        store.duplicateTemplate(project.textTemplates[0].id)

        let copy = try #require(store.project.textTemplates.last)
        #expect(plateSpec(copy)?.fitToNodeID == textNode(copy)?.id)
    }
}

/// 文字をクリップの変形より前に切り落とさないこと。
struct TextClippingTests {

    @Test("キャンバスの下へはみ出す文字も、はみ出した分まで描いておく")
    func keepsTextBeyondTheCanvas() throws {
        var template = TextTemplate.subtitle()
        // 本文と背景板をキャンバスの下端より下へずらす。
        template.nodes = template.nodes.map { node in
            var n = node
            n.frame.y = 1.1
            return n
        }
        let size = CGSize(width: 1280, height: 720)
        let raster = try #require(TextRasterizer.shared.rasterize(
            template: template, props: template.defaultProps, canvas: size))
        #expect(raster.rect.maxY > size.height)
        #expect(raster.image.height == Int(raster.rect.height))
    }

    @Test("どれだけ外へ置いても描画範囲はキャンバスの周囲 1 枚ぶんで止まる")
    func boundsStayLimited() throws {
        var template = TextTemplate.subtitle()
        template.nodes = template.nodes.map { node in
            var n = node
            n.frame.y = 50
            return n
        }
        let size = CGSize(width: 1280, height: 720)
        let raster = TextRasterizer.shared.rasterize(
            template: template, props: template.defaultProps, canvas: size)
        if let raster {
            #expect(raster.rect.maxY <= size.height * 2)
        }
    }
}
