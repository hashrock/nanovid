import Testing
import Foundation
@testable import Nanovid

/// 映像や画像の置き場所の計算。
/// コンポジタとプレビューのハンドルがここを共有しているので、
/// ここがずれると「掴んだ枠」と「映っているもの」が食い違う。
struct MediaLayoutTests {

    private let hd = CGSize(width: 1920, height: 1080)
    private let canvas = CGSize(width: 1280, height: 720)

    @Test("同じ比の素材は等倍でキャンバスいっぱいになる")
    func sameAspectFillsCanvas() {
        let rect = MediaLayout.rect(naturalSize: hd, transform: .identity, canvas: canvas)
        #expect(abs(rect.width - canvas.width) < 1e-9)
        #expect(abs(rect.height - canvas.height) < 1e-9)
        #expect(abs(rect.minX) < 1e-9)
        #expect(abs(rect.minY) < 1e-9)
    }

    @Test("縦長のキャンバスでは上下に余白ができる")
    func letterboxesOnTallCanvas() {
        let short = CGSize(width: 1080, height: 1920)
        let rect = MediaLayout.rect(naturalSize: hd, transform: .identity, canvas: short)
        #expect(abs(rect.width - 1080) < 1e-9)
        #expect(abs(rect.height - 607.5) < 1e-6)
        #expect(abs(rect.midY - 960) < 1e-6, "縦の中央に来る")
    }

    @Test("位置は中心を動かす")
    func positionMovesCenter() {
        var transform = Transform2D.identity
        transform.position = CGPoint(x: 0.25, y: -0.1)
        let rect = MediaLayout.rect(naturalSize: hd, transform: transform, canvas: canvas)
        #expect(abs(rect.midX - (640 + 0.25 * 1280)) < 1e-9)
        #expect(abs(rect.midY - (360 - 0.1 * 720)) < 1e-9)
    }

    @Test("倍率は基準の大きさに掛かる")
    func scaleMultipliesTheFittedSize() {
        var transform = Transform2D.identity
        transform.scale = 0.5
        let rect = MediaLayout.rect(naturalSize: hd, transform: transform, canvas: canvas)
        #expect(abs(rect.width - 640) < 1e-9)
        #expect(abs(rect.midX - 640) < 1e-9, "中心は動かない")
    }

    @Test("矩形から transform へ戻せる", arguments: [
        Transform2D(position: .zero, scale: 1, rotation: 0),
        Transform2D(position: CGPoint(x: 0.2, y: -0.3), scale: 0.4, rotation: 0),
        Transform2D(position: CGPoint(x: -0.9, y: 0.75), scale: 2.5, rotation: 0),
    ])
    func roundTrip(transform: Transform2D) {
        let rect = MediaLayout.rect(naturalSize: hd, transform: transform, canvas: canvas)
        let back = MediaLayout.transform(for: rect, naturalSize: hd, canvas: canvas)
        #expect(abs(back.position.x - transform.position.x) < 1e-9)
        #expect(abs(back.position.y - transform.position.y) < 1e-9)
        #expect(abs(back.scale - transform.scale) < 1e-9)
    }

    // MARK: - 隅を掴んで大きさを変える

    @Test("掴んだ隅の対角は動かない", arguments: MediaLayout.Corner.allCases)
    func oppositeCornerStaysPut(corner: MediaLayout.Corner) {
        let rect = MediaLayout.rect(naturalSize: hd, transform: .identity, canvas: canvas)
        let anchor = corner.opposite.point(in: rect)
        let grabbed = corner.point(in: rect)
        // 対角から見て 1.5 倍のところへ引っぱる
        let target = CGPoint(x: anchor.x + (grabbed.x - anchor.x) * 1.5,
                             y: anchor.y + (grabbed.y - anchor.y) * 1.5)

        let resized = MediaLayout.resized(rect, corner: corner, to: target,
                                          naturalSize: hd, canvas: canvas)
        let movedAnchor = corner.opposite.point(in: resized)
        #expect(abs(movedAnchor.x - anchor.x) < 1e-6)
        #expect(abs(movedAnchor.y - anchor.y) < 1e-6)
        #expect(abs(resized.width - rect.width * 1.5) < 1e-6)
    }

    @Test("縦横の比は保たれる")
    func keepsAspectRatio() {
        let rect = MediaLayout.rect(naturalSize: hd, transform: .identity, canvas: canvas)
        // わざと対角線から外れた点へ引く
        let target = CGPoint(x: rect.maxX + 300, y: rect.maxY - 100)
        let resized = MediaLayout.resized(rect, corner: .bottomRight, to: target,
                                          naturalSize: hd, canvas: canvas)
        #expect(abs(resized.width / resized.height - rect.width / rect.height) < 1e-9)
    }

    @Test("小さくしすぎない")
    func clampsAtMinimum() {
        let rect = MediaLayout.rect(naturalSize: hd, transform: .identity, canvas: canvas)
        let anchor = MediaLayout.Corner.bottomRight.opposite.point(in: rect)
        let resized = MediaLayout.resized(rect, corner: .bottomRight, to: anchor,
                                          naturalSize: hd, canvas: canvas)
        let back = MediaLayout.transform(for: resized, naturalSize: hd, canvas: canvas)
        #expect(back.scale >= 0.02 - 1e-9)
        #expect(resized.width > 0)
    }

    @Test("引っぱったぶんだけ倍率が変わる")
    func resizeChangesScaleProportionally() {
        var transform = Transform2D.identity
        transform.scale = 1
        let rect = MediaLayout.rect(naturalSize: hd, transform: transform, canvas: canvas)
        let anchor = MediaLayout.Corner.topLeft.point(in: rect)
        let grabbed = MediaLayout.Corner.bottomRight.point(in: rect)
        let half = CGPoint(x: anchor.x + (grabbed.x - anchor.x) * 0.5,
                           y: anchor.y + (grabbed.y - anchor.y) * 0.5)

        let resized = MediaLayout.resized(rect, corner: .bottomRight, to: half,
                                          naturalSize: hd, canvas: canvas)
        let back = MediaLayout.transform(for: resized, naturalSize: hd, canvas: canvas)
        #expect(abs(back.scale - 0.5) < 1e-6)
    }

    @Test("素材の大きさが 0 でも落ちない")
    func handlesZeroSize() {
        let rect = MediaLayout.rect(naturalSize: .zero, transform: .identity, canvas: canvas)
        #expect(rect.width == 0)
        let back = MediaLayout.transform(for: rect, naturalSize: .zero, canvas: canvas)
        #expect(back.scale == 1)
    }
}
