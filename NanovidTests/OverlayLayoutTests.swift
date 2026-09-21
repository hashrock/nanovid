import Testing
import Foundation
@testable import Nanovid

/// テキストの置き場所の計算。
/// コンポジタ（Core Image への変換）とプレビューのハンドルが同じ式を使っていることを
/// ここで固定する。別々になると「掴んだ枠」と「映っている字幕」が食い違う。
struct OverlayLayoutTests {

    private let canvas = CGSize(width: 1280, height: 720)
    /// テンプレートが決めた位置（画面下寄りの字幕を想定）。
    private let content = CGRect(x: 240, y: 560, width: 800, height: 90)

    @Test("等倍・位置ゼロならテンプレートの位置そのまま")
    func identityKeepsTemplatePosition() {
        let rect = OverlayLayout.rect(content: content, transform: .identity, canvas: canvas)
        #expect(abs(rect.minX - content.minX) < 1e-9)
        #expect(abs(rect.minY - content.minY) < 1e-9)
        #expect(abs(rect.width - content.width) < 1e-9)
    }

    @Test("位置はキャンバスの割合で動く")
    func positionMovesByCanvasFraction() {
        var transform = Transform2D.identity
        transform.position = CGPoint(x: 0.1, y: -0.25)
        let rect = OverlayLayout.rect(content: content, transform: transform, canvas: canvas)
        #expect(abs(rect.minX - (content.minX + 128)) < 1e-9)
        #expect(abs(rect.minY - (content.minY - 180)) < 1e-9)
    }

    @Test("拡大はキャンバスの中心まわり")
    func scaleIsAroundTheCanvasCenter() {
        var transform = Transform2D.identity
        transform.scale = 2
        let rect = OverlayLayout.rect(content: content, transform: transform, canvas: canvas)
        // 中心から見て 2 倍の位置・2 倍の大きさ
        #expect(abs(rect.midX - (640 + (content.midX - 640) * 2)) < 1e-9)
        #expect(abs(rect.midY - (360 + (content.midY - 360) * 2)) < 1e-9)
        #expect(abs(rect.width - content.width * 2) < 1e-9)
    }

    @Test("矩形から transform へ戻せる", arguments: [
        Transform2D(position: .zero, scale: 1, rotation: 0),
        Transform2D(position: CGPoint(x: 0.15, y: -0.3), scale: 0.6, rotation: 0),
        Transform2D(position: CGPoint(x: -0.4, y: 0.2), scale: 1.8, rotation: 0),
    ])
    func roundTrip(transform: Transform2D) {
        let rect = OverlayLayout.rect(content: content, transform: transform, canvas: canvas)
        let back = OverlayLayout.transform(for: rect, content: content, canvas: canvas)
        #expect(abs(back.position.x - transform.position.x) < 1e-9)
        #expect(abs(back.position.y - transform.position.y) < 1e-9)
        #expect(abs(back.scale - transform.scale) < 1e-9)
    }

    @Test("描画に使う変換と、ハンドルに使う矩形が一致する", arguments: [
        Transform2D(position: .zero, scale: 1, rotation: 0),
        Transform2D(position: CGPoint(x: 0.2, y: 0.1), scale: 1, rotation: 0),
        Transform2D(position: CGPoint(x: -0.3, y: 0.25), scale: 0.5, rotation: 0),
        Transform2D(position: CGPoint(x: 0.05, y: -0.15), scale: 2.2, rotation: 0),
    ])
    func drawingAndHandlesAgree(transform: Transform2D) {
        // コンポジタは CIImage（原点 0,0・大きさ content.size）へこの変換をかける。
        let affine = OverlayLayout.ciTransform(content: content, transform: transform,
                                               canvas: canvas)
        let a = CGPoint(x: 0, y: 0).applying(affine)
        let b = CGPoint(x: content.width, y: content.height).applying(affine)

        // Core Image は左下原点。キャンバス座標（左上原点）へ直す。
        let drawn = CGRect(x: min(a.x, b.x),
                           y: canvas.height - max(a.y, b.y),
                           width: abs(b.x - a.x),
                           height: abs(b.y - a.y))
        let expected = OverlayLayout.rect(content: content, transform: transform, canvas: canvas)

        #expect(abs(drawn.minX - expected.minX) < 1e-6, "左端がずれている")
        #expect(abs(drawn.minY - expected.minY) < 1e-6, "上端がずれている")
        #expect(abs(drawn.width - expected.width) < 1e-6)
        #expect(abs(drawn.height - expected.height) < 1e-6)
    }

    @Test("隅を掴んで縮めても対角は動かない")
    func resizeKeepsOppositeCorner() {
        let rect = OverlayLayout.rect(content: content, transform: .identity, canvas: canvas)
        let anchor = MediaLayout.Corner.bottomRight.opposite.point(in: rect)
        let grabbed = MediaLayout.Corner.bottomRight.point(in: rect)
        let half = CGPoint(x: anchor.x + (grabbed.x - anchor.x) * 0.5,
                           y: anchor.y + (grabbed.y - anchor.y) * 0.5)

        let resized = MediaLayout.resized(rect, corner: .bottomRight, to: half, minimumWidth: 8)
        let back = OverlayLayout.transform(for: resized, content: content, canvas: canvas)
        #expect(abs(back.scale - 0.5) < 1e-6)

        // 戻した transform で置き直しても、左上は動いていない
        let placed = OverlayLayout.rect(content: content, transform: back, canvas: canvas)
        #expect(abs(placed.minX - rect.minX) < 1e-6)
        #expect(abs(placed.minY - rect.minY) < 1e-6)
    }

    @Test("大きさが 0 でも落ちない")
    func handlesEmptyContent() {
        let back = OverlayLayout.transform(for: .zero, content: .zero, canvas: canvas)
        #expect(back.scale == 1)
    }
}
