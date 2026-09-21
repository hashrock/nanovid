import CoreGraphics
import Foundation

/// 出荷時に同梱するテンプレート。アプリ内エディタで自由に複製・改変できる。
extension TextTemplate {

    /// 字幕：背景板がテキストの実測幅に追従する。
    static func subtitle() -> TextTemplate {
        let textID = UUID()
        let textNode = TemplateNode(
            id: textID,
            name: "本文",
            frame: RelFrame(x: 0.5, y: 0.88, width: 0.86, height: 0.12, anchor: .bottom),
            kind: .text(TextNodeSpec(
                text: .prop("text"),
                color: .prop("textColor"),
                font: FontSpec(name: "", relativeSize: 0.055, weight: 0.4),
                align: .center,
                lineSpacing: 0.15,
                strokeWidth: 0,
                shadowRadius: 0.004
            ))
        )
        let plate = TemplateNode(
            name: "背景板",
            frame: RelFrame(x: 0.5, y: 0.88, width: 0.86, height: 0.12, anchor: .bottom),
            kind: .rect(RectNodeSpec(
                fill: .prop("plateColor"),
                cornerRadius: 0.012,
                fitToNodeID: textID,
                padding: CGPoint(x: 0.022, y: 0.016)
            ))
        )
        return TextTemplate(
            name: "字幕",
            nodes: [plate, textNode],
            props: [
                PropDef(key: "text", label: "テキスト", type: .string, defaultValue: .string("ここに字幕")),
                PropDef(key: "textColor", label: "文字色", type: .color, defaultValue: .color(.white)),
                PropDef(key: "plateColor", label: "背景色", type: .color,
                        defaultValue: .color(RGBAColor(r: 0, g: 0, b: 0, a: 0.66))),
            ]
        )
    }

    /// シンプル字幕：背景板なし。縁取りだけで背景から浮かせる。
    static func plainSubtitle() -> TextTemplate {
        let node = TemplateNode(
            name: "本文",
            frame: RelFrame(x: 0.5, y: 0.9, width: 0.88, height: 0.12, anchor: .bottom),
            kind: .text(TextNodeSpec(
                text: .prop("text"),
                color: .prop("textColor"),
                font: FontSpec(name: "", relativeSize: 0.058, weight: 0.56),
                align: .center,
                lineSpacing: 0.14,
                strokeWidth: 0.09,
                strokeColor: .prop("strokeColor"),
                shadowRadius: 0.005,
                shadowColor: .literal(.color(RGBAColor(r: 0, g: 0, b: 0, a: 0.5))),
                shadowOffset: CGPoint(x: 0, y: 0.002)
            ))
        )
        return TextTemplate(
            name: "シンプル字幕",
            nodes: [node],
            props: [
                PropDef(key: "text", label: "テキスト", type: .string, defaultValue: .string("ここに字幕")),
                PropDef(key: "textColor", label: "文字色", type: .color, defaultValue: .color(.white)),
                PropDef(key: "strokeColor", label: "縁の色", type: .color, defaultValue: .color(.black)),
            ]
        )
    }

    /// テロップ：左下に小さく置く注釈。スクリーンキャストの補足向け。
    static func lowerLeftNote() -> TextTemplate {
        let textID = UUID()
        let text = TemplateNode(
            id: textID,
            name: "本文",
            frame: RelFrame(x: 0.05, y: 0.92, width: 0.55, height: 0.08, anchor: .bottomLeft),
            kind: .text(TextNodeSpec(
                text: .prop("text"),
                color: .prop("textColor"),
                font: FontSpec(name: "", relativeSize: 0.034, weight: 0.45),
                align: .left,
                lineSpacing: 0.12,
                shadowRadius: 0.003
            ))
        )
        let plate = TemplateNode(
            name: "背景板",
            frame: RelFrame(x: 0.05, y: 0.92, width: 0.55, height: 0.08, anchor: .bottomLeft),
            kind: .rect(RectNodeSpec(
                fill: .prop("plateColor"),
                cornerRadius: 0.008,
                fitToNodeID: textID,
                padding: CGPoint(x: 0.016, y: 0.012)
            ))
        )
        return TextTemplate(
            name: "テロップ（左下）",
            nodes: [plate, text],
            props: [
                PropDef(key: "text", label: "テキスト", type: .string, defaultValue: .string("補足メモ")),
                PropDef(key: "textColor", label: "文字色", type: .color, defaultValue: .color(.white)),
                PropDef(key: "plateColor", label: "背景色", type: .color,
                        defaultValue: .color(RGBAColor(hex: "#000000A6") ?? .black)),
            ]
        )
    }

    /// タイトル：大見出し＋サブ。アクセントの帯付き。
    static func title() -> TextTemplate {
        let bar = TemplateNode(
            name: "アクセント",
            frame: RelFrame(x: 0.12, y: 0.5, width: 0.006, height: 0.2, anchor: .left),
            kind: .rect(RectNodeSpec(fill: .prop("accent"), cornerRadius: 0.003, fitToNodeID: nil))
        )
        let title = TemplateNode(
            name: "見出し",
            frame: RelFrame(x: 0.145, y: 0.455, width: 0.72, height: 0.14, anchor: .bottomLeft),
            kind: .text(TextNodeSpec(
                text: .prop("title"),
                color: .prop("titleColor"),
                font: FontSpec(relativeSize: 0.095, weight: 0.62),
                align: .left,
                lineSpacing: 0.08,
                shadowRadius: 0.004
            ))
        )
        let sub = TemplateNode(
            name: "サブ",
            frame: RelFrame(x: 0.145, y: 0.5, width: 0.72, height: 0.08, anchor: .topLeft),
            kind: .text(TextNodeSpec(
                text: .prop("subtitle"),
                color: .prop("accent"),
                font: FontSpec(relativeSize: 0.042, weight: 0.4),
                align: .left,
                lineSpacing: 0.1,
                shadowRadius: 0.003
            ))
        )
        return TextTemplate(
            name: "タイトル",
            nodes: [bar, title, sub],
            props: [
                PropDef(key: "title", label: "見出し", type: .string, defaultValue: .string("タイトル")),
                PropDef(key: "subtitle", label: "サブ", type: .string, defaultValue: .string("subtitle")),
                PropDef(key: "titleColor", label: "見出し色", type: .color, defaultValue: .color(.white)),
                PropDef(key: "accent", label: "アクセント", type: .color,
                        defaultValue: .color(RGBAColor(hex: "#4FC3F7") ?? .white)),
            ]
        )
    }
}
