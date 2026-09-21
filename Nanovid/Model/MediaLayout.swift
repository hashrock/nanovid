import CoreGraphics
import Foundation

/// 映像や画像をキャンバスのどこに、どの大きさで置くか。
///
/// 実際に描くコンポジタと、プレビュー上のハンドルの両方がここを通る。
/// 別々に計算すると、掴んだ枠と映っているものがずれてしまう。
enum MediaLayout {

    /// 素材をキャンバスに収めたときの基準倍率（transform.scale が 1 のときの大きさ）。
    static func fitScale(_ size: CGSize, in canvas: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(canvas.width / size.width, canvas.height / size.height)
    }

    /// キャンバス座標（左上原点、y は下が正）での配置矩形。
    static func rect(naturalSize size: CGSize,
                     transform: Transform2D,
                     canvas: CGSize) -> CGRect {
        let scale = fitScale(size, in: canvas) * transform.scale
        let width = size.width * scale
        let height = size.height * scale
        let centerX = canvas.width / 2 + transform.position.x * canvas.width
        let centerY = canvas.height / 2 + transform.position.y * canvas.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2,
                      width: width, height: height)
    }

    /// 矩形から transform を逆に求める。ハンドルで動かした結果を書き戻すのに使う。
    static func transform(for rect: CGRect,
                          naturalSize size: CGSize,
                          canvas: CGSize,
                          rotation: Double = 0) -> Transform2D {
        let fit = fitScale(size, in: canvas)
        guard size.width > 0, fit > 0, canvas.width > 0, canvas.height > 0 else {
            return Transform2D(position: .zero, scale: 1, rotation: rotation)
        }
        return Transform2D(
            position: CGPoint(x: (rect.midX - canvas.width / 2) / canvas.width,
                              y: (rect.midY - canvas.height / 2) / canvas.height),
            scale: (rect.width / size.width) / fit,
            rotation: rotation)
    }

    /// 四隅。ハンドルの位置と、掴んだときの対角を出すのに使う。
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }

    /// 隅を掴んで動かしたときの新しい矩形。対角は動かさない。
    /// 縦横の比は保つので、掴んだ点は対角線の上に乗せる。
    /// - Parameter minimumWidth: これより小さくはしない（キャンバス座標での幅）。
    static func resized(_ rect: CGRect,
                        corner: Corner,
                        to point: CGPoint,
                        minimumWidth: Double) -> CGRect {
        let anchor = corner.opposite.point(in: rect)
        let grabbed = corner.point(in: rect)
        let diagonal = CGPoint(x: grabbed.x - anchor.x, y: grabbed.y - anchor.y)
        let lengthSquared = diagonal.x * diagonal.x + diagonal.y * diagonal.y
        guard lengthSquared > 0 else { return rect }

        // 掴んだ点を対角線へ射影する。斜めに引いても比が崩れない。
        let moved = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        var ratio = (moved.x * diagonal.x + moved.y * diagonal.y) / lengthSquared

        if rect.width > 0, rect.width * ratio < minimumWidth {
            ratio = minimumWidth / rect.width
        }

        let width = rect.width * ratio
        let height = rect.height * ratio
        let originX = corner == .topLeft || corner == .bottomLeft ? anchor.x - width : anchor.x
        let originY = corner == .topLeft || corner == .topRight ? anchor.y - height : anchor.y
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
