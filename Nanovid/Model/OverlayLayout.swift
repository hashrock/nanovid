import CoreGraphics
import Foundation

/// テキストのように、すでにキャンバス座標で置き場所が決まっているものの配置。
///
/// 映像（MediaLayout）とは基準が違う。映像は素材の中心を動かすが、こちらは
/// テンプレートが決めた位置を土台にして、キャンバスの中心まわりに拡大し、
/// そのうえで位置をずらす。テンプレートのレイアウトを保ったまま
/// インスタンス側で微調整できるようにするため。
enum OverlayLayout {

    /// キャンバス座標（左上原点）での配置矩形。
    /// - Parameter content: ラスタライズした結果の矩形（テンプレートが決めた位置）。
    static func rect(content: CGRect, transform: Transform2D, canvas: CGSize) -> CGRect {
        let centerX = canvas.width / 2
        let centerY = canvas.height / 2
        let scale = transform.scale
        return CGRect(
            x: centerX + transform.position.x * canvas.width + scale * (content.minX - centerX),
            y: centerY + transform.position.y * canvas.height + scale * (content.minY - centerY),
            width: content.width * scale,
            height: content.height * scale)
    }

    /// 矩形から transform を逆に求める。ハンドルで動かした結果を書き戻すのに使う。
    static func transform(for rect: CGRect,
                          content: CGRect,
                          canvas: CGSize,
                          rotation: Double = 0) -> Transform2D {
        guard content.width > 0, canvas.width > 0, canvas.height > 0 else {
            return Transform2D(position: .zero, scale: 1, rotation: rotation)
        }
        let centerX = canvas.width / 2
        let centerY = canvas.height / 2
        let scale = rect.width / content.width
        return Transform2D(
            position: CGPoint(
                x: (rect.minX - centerX - scale * (content.minX - centerX)) / canvas.width,
                y: (rect.minY - centerY - scale * (content.minY - centerY)) / canvas.height),
            scale: scale,
            rotation: rotation)
    }

    /// Core Image へ渡す変換（左下原点）。コンポジタはこれを使う。
    /// 上の rect と同じ式から作っているので、ハンドルの枠と映るものがずれない。
    static func ciTransform(content: CGRect,
                            transform: Transform2D,
                            canvas: CGSize) -> CGAffineTransform {
        // ラスタライズ結果をキャンバス座標の位置へ置く（y を反転）。
        let base = CGAffineTransform(translationX: content.minX,
                                     y: canvas.height - content.maxY)
        guard transform.scale != 1 || transform.rotation != 0
                || transform.position != .zero else { return base }

        let centerX = canvas.width / 2
        let centerY = canvas.height / 2
        let dx = transform.position.x * canvas.width
        let dy = -transform.position.y * canvas.height   // 画面下方向を正にする
        let around = CGAffineTransform.identity
            .translatedBy(x: centerX + dx, y: centerY + dy)
            .rotated(by: transform.rotation)
            .scaledBy(x: transform.scale, y: transform.scale)
            .translatedBy(x: -centerX, y: -centerY)
        return base.concatenating(around)
    }
}
