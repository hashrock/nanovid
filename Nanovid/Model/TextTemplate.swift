import CoreGraphics
import Foundation

// MARK: - props の値

enum PropValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case color(RGBAColor)
    case point(CGPoint)
    case bool(Bool)

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var colorValue: RGBAColor? { if case .color(let v) = self { return v }; return nil }
    var pointValue: CGPoint? { if case .point(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }

    var type: PropType {
        switch self {
        case .string: return .string
        case .number: return .number
        case .color: return .color
        case .point: return .point
        case .bool: return .bool
        }
    }

    /// 一括編集の表やインスペクタでの表示用。
    var displayText: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(format: "%g", v)
        case .color(let v): return v.hexString
        case .point(let v): return String(format: "%g, %g", v.x, v.y)
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

enum PropType: String, Codable, Hashable, CaseIterable {
    case string, number, color, point, bool

    var label: String {
        switch self {
        case .string: return "テキスト"
        case .number: return "数値"
        case .color: return "色"
        case .point: return "座標"
        case .bool: return "ON/OFF"
        }
    }

    var defaultValue: PropValue {
        switch self {
        case .string: return .string("")
        case .number: return .number(0)
        case .color: return .color(.white)
        case .point: return .point(.zero)
        case .bool: return .bool(false)
        }
    }
}

/// テンプレートが公開する上書き可能なプロパティ。
struct PropDef: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// インスタンス側の props 辞書のキー。テンプレート内で一意。
    var key: String
    var label: String
    var type: PropType
    var defaultValue: PropValue
    /// 一括編集の表に既定で出すか。
    var showInBulkEditor: Bool = true
}

/// ノードのプロパティは「固定値」か「props へのバインド」のどちらか。
enum ValueRef: Codable, Hashable {
    case literal(PropValue)
    case prop(String)

    func resolve(_ props: [String: PropValue], defaults: [String: PropValue]) -> PropValue? {
        switch self {
        case .literal(let v):
            return v
        case .prop(let key):
            return props[key] ?? defaults[key]
        }
    }

    var boundKey: String? { if case .prop(let k) = self { return k }; return nil }
}

// MARK: - レイアウト

enum Anchor: String, Codable, Hashable, CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .top: return "上"
        case .topRight: return "右上"
        case .left: return "左"
        case .center: return "中央"
        case .right: return "右"
        case .bottomLeft: return "左下"
        case .bottom: return "下"
        case .bottomRight: return "右下"
        }
    }

    /// 0..1 の単位矩形内での基準点。y は上方向が 0。
    var unitPoint: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

/// キャンバスサイズに対する相対フレーム(0..1)。解像度を変えてもレイアウトが崩れない。
struct RelFrame: Codable, Hashable {
    /// アンカー位置。キャンバス左上を (0,0)、右下を (1,1) とする。
    var x: Double = 0.5
    var y: Double = 0.85
    /// 幅はキャンバス幅に対する割合。テキストはこの幅で折り返す。
    var width: Double = 0.8
    /// 高さはキャンバス高さに対する割合。テキストノードでは autoHeight が真なら無視される。
    var height: Double = 0.15
    var anchor: Anchor = .center

    /// 実ピクセルの矩形（左上原点）を返す。
    func rect(in canvas: CGSize, measuredHeight: Double? = nil) -> CGRect {
        let w = width * canvas.width
        let h = (measuredHeight ?? (height * canvas.height))
        let ax = x * canvas.width
        let ay = y * canvas.height
        let u = anchor.unitPoint
        return CGRect(x: ax - w * u.x, y: ay - h * u.y, width: w, height: h)
    }
}

// MARK: - ノード

enum TextAlign: String, Codable, Hashable, CaseIterable {
    case left, center, right

    var label: String {
        switch self {
        case .left: return "左"
        case .center: return "中央"
        case .right: return "右"
        }
    }
}

struct FontSpec: Codable, Hashable {
    /// PostScript 名。空なら系統フォント。
    var name: String = ""
    /// キャンバス高さに対する割合で指定する。解像度非依存にするため。
    var relativeSize: Double = 0.06
    var weight: Double = 0.4  // NSFont.Weight 相当 (-1...1)

    func pointSize(in canvas: CGSize) -> Double { relativeSize * canvas.height }
}

struct TextNodeSpec: Codable, Hashable {
    var text: ValueRef = .literal(.string("テキスト"))
    var color: ValueRef = .literal(.color(.white))
    var font: FontSpec = FontSpec()
    var align: TextAlign = .center
    var lineSpacing: Double = 0.1        // 行送りの追加分（フォントサイズ比）
    /// 縁取り。0 なら無し。
    var strokeWidth: Double = 0
    var strokeColor: ValueRef = .literal(.color(.black))
    /// 影。
    var shadowRadius: Double = 0
    var shadowColor: ValueRef = .literal(.color(RGBAColor(r: 0, g: 0, b: 0, a: 0.6)))
    /// キャンバス高さに対する割合。y は画面下方向が正。
    var shadowOffset: CGPoint = CGPoint(x: 0, y: 0.003)
}

struct RectNodeSpec: Codable, Hashable {
    var fill: ValueRef = .literal(.color(RGBAColor(r: 0, g: 0, b: 0, a: 0.6)))
    var cornerRadius: Double = 0.01      // キャンバス高さ比
    /// 指定したテキストノードの実測サイズに合わせて追従する（字幕の背景板用）。
    var fitToNodeID: UUID?
    /// fitToNodeID 使用時の余白（キャンバス高さ比）。
    var padding: CGPoint = CGPoint(x: 0.02, y: 0.01)
}

enum NodeKind: Codable, Hashable {
    case text(TextNodeSpec)
    case rect(RectNodeSpec)
}

struct TemplateNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "ノード"
    var frame: RelFrame = RelFrame()
    var opacity: Double = 1
    var isHidden: Bool = false
    var kind: NodeKind
}

// MARK: - テンプレート

struct TextTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// 背面から前面の順。
    var nodes: [TemplateNode]
    var props: [PropDef]

    var defaultProps: [String: PropValue] {
        Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0.defaultValue) })
    }

    func propDef(for key: String) -> PropDef? { props.first { $0.key == key } }
}

/// タイムライン上に置かれるテキストレイヤー。テンプレートを参照し、props だけを持つ。
struct TextInstance: Codable, Hashable {
    var templateID: UUID
    /// テンプレートの既定値から変更した分だけを保持する。
    var props: [String: PropValue] = [:]

    func value(_ key: String, in template: TextTemplate) -> PropValue? {
        props[key] ?? template.propDef(for: key)?.defaultValue
    }

    func resolvedProps(in template: TextTemplate) -> [String: PropValue] {
        template.defaultProps.merging(props) { _, override in override }
    }
}
