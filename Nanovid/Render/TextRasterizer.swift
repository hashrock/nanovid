import AppKit
import CoreGraphics
import CoreText
import Foundation

/// ラスタライズ結果。キャンバス全面ではなく実際に描いた範囲だけを持つ。
struct RasterizedText {
    let image: CGImage
    /// キャンバス座標（左上原点）での配置矩形。
    let rect: CGRect
}

/// テンプレート＋props＋キャンバスサイズから 1 枚の CGImage を作る。
/// 内容が変わらない限りキャッシュを返すので、再生時に毎フレーム再描画されない。
final class TextRasterizer {
    static let shared = TextRasterizer()

    private let lock = NSLock()
    private var cache: [String: RasterizedText] = [:]
    private var order: [String] = []
    private let limit = 64

    private init() {}

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }

    func rasterize(template: TextTemplate, props: [String: PropValue], canvas: CGSize) -> RasterizedText? {
        let key = cacheKey(template: template, props: props, canvas: canvas)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let made = render(template: template, props: props, canvas: canvas) else { return nil }

        lock.lock()
        cache[key] = made
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return made
    }

    private func cacheKey(template: TextTemplate, props: [String: PropValue], canvas: CGSize) -> String {
        var hasher = Hasher()
        hasher.combine(template)
        for k in props.keys.sorted() {
            hasher.combine(k)
            hasher.combine(props[k])
        }
        hasher.combine(canvas.width)
        hasher.combine(canvas.height)
        return String(hasher.finalize())
    }

    // MARK: - 実描画

    private func render(template: TextTemplate, props: [String: PropValue], canvas: CGSize) -> RasterizedText? {
        let defaults = template.defaultProps
        let resolved = defaults.merging(props) { _, o in o }

        // 1) まずテキストノードを実測し、各ノードの最終矩形を確定させる。
        var layouts: [UUID: NodeLayout] = [:]
        for node in template.nodes where !node.isHidden {
            if case .text(let spec) = node.kind {
                guard let l = measureText(node: node, spec: spec, props: resolved, canvas: canvas) else { continue }
                layouts[node.id] = l
            }
        }
        for node in template.nodes where !node.isHidden {
            if case .rect(let spec) = node.kind {
                layouts[node.id] = layoutRect(node: node, spec: spec, canvas: canvas, textLayouts: layouts)
            }
        }
        guard !layouts.isEmpty else { return nil }

        // 2) 実際に描かれる範囲＋影/縁取りの余裕をとって、描画バッファのサイズを決める。
        //    折り返し幅ではなく行の実測幅で囲むので、短い字幕ではバッファがぐっと小さくなる。
        let maxStroke = layouts.values.map(\.strokePoints).max() ?? 0
        let margin = max(canvas.height * 0.03, maxStroke * 1.5)
        var bounds = layouts.values.map(\.inkRect).reduce(CGRect.null) { $0.union($1) }
        bounds = bounds.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: canvas))
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        bounds = bounds.integral

        let w = Int(bounds.width), h = Int(bounds.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)   // 動画用途ではサブピクセル描画は避ける
        ctx.setShouldAntialias(true)

        // CoreGraphics は左下原点。テンプレートの矩形（左上原点）を変換して描く。
        func toCG(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - bounds.minX,
                   y: bounds.maxY - r.maxY,
                   width: r.width, height: r.height)
        }

        // 3) 背面から順に描く。
        for node in template.nodes where !node.isHidden {
            guard let layout = layouts[node.id] else { continue }
            ctx.saveGState()
            ctx.setAlpha(node.opacity)
            switch node.kind {
            case .rect(let spec):
                drawRect(spec, in: ctx, rect: toCG(layout.rect), props: resolved, canvas: canvas)
            case .text(let spec):
                drawText(spec, in: ctx, layout: layout, rect: toCG(layout.rect), props: resolved, canvas: canvas)
            }
            ctx.restoreGState()
        }

        guard let image = ctx.makeImage() else { return nil }
        return RasterizedText(image: image, rect: bounds)
    }

    // MARK: - レイアウト

    private struct NodeLayout {
        /// キャンバス座標（左上原点）での矩形。テキストでは折り返し幅ぶんの枠。
        var rect: CGRect
        /// 実際に色が乗る範囲。テキストは行の最大幅に合わせて詰めてある。
        /// 描画バッファのサイズ決めと、背景板の追従に使う。
        var inkRect: CGRect
        var framesetter: CTFramesetter?
        /// 縁取り用。塗りとは別パスで描く。
        var strokeFramesetter: CTFramesetter?
        /// 縁取りの実太さ(pt)。バッファの余白計算に使う。
        var strokePoints: CGFloat = 0
    }

    private func measureText(node: TemplateNode, spec: TextNodeSpec,
                             props: [String: PropValue], canvas: CGSize) -> NodeLayout? {
        let string = spec.text.resolve(props, defaults: [:])?.stringValue ?? ""
        guard !string.isEmpty else { return nil }

        let attr = attributedString(spec, text: string, props: props, canvas: canvas, pass: .fill)
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let wrapWidth = node.frame.width * canvas.width
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: wrapWidth, height: .greatestFiniteMagnitude), &fitRange
        )

        // 描画用の枠は折り返し幅のまま（整列は枠内で行う）。高さだけ実測に合わせる。
        let rect = node.frame.rect(in: canvas, measuredHeight: ceil(suggested.height))
        let ink = Self.inkRect(in: rect, inkWidth: ceil(suggested.width), align: spec.align)

        var strokeFS: CTFramesetter?
        var strokePoints: CGFloat = 0
        if spec.strokeWidth > 0 {
            let strokeAttr = attributedString(spec, text: string, props: props,
                                              canvas: canvas, pass: .stroke)
            strokeFS = CTFramesetterCreateWithAttributedString(strokeAttr)
            strokePoints = spec.strokeWidth * spec.font.pointSize(in: canvas)
        }
        return NodeLayout(rect: rect, inkRect: ink, framesetter: fs,
                          strokeFramesetter: strokeFS, strokePoints: strokePoints)
    }

    /// 整列を踏まえて、枠 rect の中で実際に文字が乗る範囲を求める。
    private static func inkRect(in rect: CGRect, inkWidth: CGFloat, align: TextAlign) -> CGRect {
        let width = min(inkWidth, rect.width)
        let x: CGFloat
        switch align {
        case .left: x = rect.minX
        case .right: x = rect.maxX - width
        case .center: x = rect.midX - width / 2
        }
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    private func layoutRect(node: TemplateNode, spec: RectNodeSpec,
                            canvas: CGSize, textLayouts: [UUID: NodeLayout]) -> NodeLayout {
        guard let targetID = spec.fitToNodeID, let target = textLayouts[targetID] else {
            let rect = node.frame.rect(in: canvas)
            return NodeLayout(rect: rect, inkRect: rect)
        }
        // 対象テキストが実際に占めている範囲に、余白を足して囲む。
        let padX = spec.padding.x * canvas.height
        let padY = spec.padding.y * canvas.height
        let rect = target.inkRect.insetBy(dx: -padX, dy: -padY)
        return NodeLayout(rect: rect, inkRect: rect)
    }

    // MARK: - 描画

    private func drawRect(_ spec: RectNodeSpec, in ctx: CGContext, rect: CGRect,
                          props: [String: PropValue], canvas: CGSize) {
        let color = spec.fill.resolve(props, defaults: [:])?.colorValue ?? .clear
        guard color.a > 0 else { return }
        let radius = min(spec.cornerRadius * canvas.height, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func drawText(_ spec: TextNodeSpec, in ctx: CGContext, layout: NodeLayout, rect: CGRect,
                          props: [String: PropValue], canvas: CGSize) {
        guard let fs = layout.framesetter else { return }
        let path = CGPath(rect: rect, transform: nil)

        func applyShadow() {
            guard spec.shadowRadius > 0 else { return }
            let sc = spec.shadowColor.resolve(props, defaults: [:])?.colorValue ?? .black
            let off = CGSize(width: spec.shadowOffset.x * canvas.height,
                             height: -spec.shadowOffset.y * canvas.height)
            ctx.setShadow(offset: off, blur: spec.shadowRadius * canvas.height, color: sc.cgColor)
        }

        // 縁取りは「輪郭だけを描いてから塗りを重ねる」2 パスにする。
        // CoreText の負の strokeWidth は輪郭が字の内側を削るので、太くすると字が痩せてしまう。
        if let strokeFS = layout.strokeFramesetter {
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            applyShadow()
            let strokeFrame = CTFramesetterCreateFrame(strokeFS, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(strokeFrame, ctx)
            ctx.restoreGState()
        } else {
            applyShadow()
        }

        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    private enum DrawPass {
        case fill
        case stroke
    }

    private func attributedString(_ spec: TextNodeSpec, text: String,
                                  props: [String: PropValue], canvas: CGSize,
                                  pass: DrawPass) -> NSAttributedString {
        let size = spec.font.pointSize(in: canvas)
        let font: NSFont
        if !spec.font.name.isEmpty, let f = NSFont(name: spec.font.name, size: size) {
            font = f
        } else {
            font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight(spec.font.weight))
        }

        let color = spec.color.resolve(props, defaults: [:])?.colorValue ?? .white
        let para = NSMutableParagraphStyle()
        para.alignment = {
            switch spec.align {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }()
        para.lineSpacing = size * spec.lineSpacing
        para.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .white,
            .paragraphStyle: para,
        ]
        if pass == .stroke {
            let sc = spec.strokeColor.resolve(props, defaults: [:])?.colorValue ?? .black
            // 正の値は「輪郭のみ」。フォントサイズに対する百分率で指定する。
            // 輪郭の半分は塗りに隠れるので、見た目の太さぶん 2 倍にしておく。
            attrs[.strokeWidth] = spec.strokeWidth * 200
            attrs[.strokeColor] = NSColor(cgColor: sc.cgColor) ?? .black
            attrs[.foregroundColor] = NSColor(cgColor: sc.cgColor) ?? .black
        }
        return NSAttributedString(string: text, attributes: attrs)
    }
}
