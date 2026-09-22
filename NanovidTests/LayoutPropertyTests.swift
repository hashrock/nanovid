import Testing
import CoreGraphics
import Foundation
@testable import Nanovid

/// 映像・画像の配置。コンポジタとプレビューのハンドルが同じ式を通る。
struct MediaLayoutPropertyTests {

    private struct Setup {
        var natural: CGSize
        var canvas: CGSize
        var transform: Transform2D
    }

    private func setup(seed: Int) -> Setup {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x3D1A)
        let canvases: [CGSize] = [CGSize(width: 1920, height: 1080),
                                  CGSize(width: 1080, height: 1920),
                                  CGSize(width: 640, height: 360)]
        return Setup(
            natural: CGSize(width: g.double(in: 16...4096), height: g.double(in: 16...4096)),
            canvas: canvases[g.int(in: 0...2)],
            transform: Transform2D(position: CGPoint(x: g.double(in: -2...2),
                                                     y: g.double(in: -2...2)),
                                   scale: g.double(in: 0.05...8),
                                   rotation: 0))
    }

    @Test("矩形と transform は行き来しても変わらない", arguments: 0..<300)
    func rectAndTransformRoundTrip(seed: Int) {
        let s = setup(seed: seed)
        let rect = MediaLayout.rect(naturalSize: s.natural, transform: s.transform, canvas: s.canvas)
        let back = MediaLayout.transform(for: rect, naturalSize: s.natural, canvas: s.canvas)
        #expect(abs(back.scale - s.transform.scale) < 1e-9, "倍率が \(back.scale) へずれた")
        #expect(abs(back.position.x - s.transform.position.x) < 1e-9)
        #expect(abs(back.position.y - s.transform.position.y) < 1e-9)
    }

    @Test("置いた矩形は素材の縦横比を保つ", arguments: 0..<300)
    func placementKeepsTheAspectRatio(seed: Int) {
        let s = setup(seed: seed)
        let rect = MediaLayout.rect(naturalSize: s.natural, transform: s.transform, canvas: s.canvas)
        let want = s.natural.width / s.natural.height
        let got = rect.width / rect.height
        #expect(abs(got / want - 1) < 1e-9, "比が \(want) から \(got) へずれた")
    }

    @Test("倍率 1 ならキャンバスに収まり、どちらかの辺がぴったり", arguments: 0..<300)
    func scaleOneFitsTheCanvas(seed: Int) {
        var s = setup(seed: seed)
        s.transform = Transform2D(position: .zero, scale: 1, rotation: 0)
        let rect = MediaLayout.rect(naturalSize: s.natural, transform: s.transform, canvas: s.canvas)
        #expect(rect.width <= s.canvas.width + 1e-6)
        #expect(rect.height <= s.canvas.height + 1e-6)
        let touchesWidth = abs(rect.width - s.canvas.width) < 1e-6
        let touchesHeight = abs(rect.height - s.canvas.height) < 1e-6
        #expect(touchesWidth || touchesHeight, "どちらの辺も接していない \(rect)")
        // 中心はキャンバスの中心。
        #expect(abs(rect.midX - s.canvas.width / 2) < 1e-6)
        #expect(abs(rect.midY - s.canvas.height / 2) < 1e-6)
    }

    @Test("隅を掴んで動かしても対角は動かない", arguments: 0..<300)
    func resizingKeepsTheOppositeCorner(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x4C09)
        let rect = CGRect(x: g.double(in: -200...800), y: g.double(in: -200...800),
                          width: g.double(in: 20...900), height: g.double(in: 20...900))
        let corner = MediaLayout.Corner.allCases[g.int(in: 0...3)]
        let point = CGPoint(x: g.double(in: -600...1600), y: g.double(in: -600...1600))

        let anchor = corner.opposite.point(in: rect)
        let resized = MediaLayout.resized(rect, corner: corner, to: point, minimumWidth: 8)
        let movedAnchor = corner.opposite.point(in: resized)
        #expect(abs(movedAnchor.x - anchor.x) < 1e-6 && abs(movedAnchor.y - anchor.y) < 1e-6,
                "対角が \(anchor) から \(movedAnchor) へ動いた（\(corner)）")
    }

    @Test("隅を掴んで動かしても縦横比は保たれる", arguments: 0..<300)
    func resizingKeepsTheAspectRatio(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x4C0A)
        let rect = CGRect(x: g.double(in: -200...800), y: g.double(in: -200...800),
                          width: g.double(in: 20...900), height: g.double(in: 20...900))
        let corner = MediaLayout.Corner.allCases[g.int(in: 0...3)]
        let point = CGPoint(x: g.double(in: -600...1600), y: g.double(in: -600...1600))

        let resized = MediaLayout.resized(rect, corner: corner, to: point, minimumWidth: 8)
        guard resized.height != 0 else { return }
        #expect(abs((resized.width / resized.height) / (rect.width / rect.height) - 1) < 1e-6,
                "比が崩れた \(rect) → \(resized)")
    }

    @Test("縮めすぎても下限より小さくならない", arguments: 0..<300)
    func resizingRespectsTheMinimum(seed: Int) {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x4C0B)
        let rect = CGRect(x: 100, y: 100, width: g.double(in: 20...900), height: g.double(in: 20...900))
        let corner = MediaLayout.Corner.allCases[g.int(in: 0...3)]
        let minimum = g.double(in: 4...40)
        // 対角そのものを掴みに行く（つぶしにかかる）。
        let point = corner.opposite.point(in: rect)

        let resized = MediaLayout.resized(rect, corner: corner, to: point, minimumWidth: minimum)
        #expect(resized.width >= minimum - 1e-6, "幅が \(resized.width) まで潰れた")
    }
}

/// テキストの配置。ハンドルの枠と、実際に描かれる位置が一致すること。
struct OverlayLayoutPropertyTests {

    private struct Setup {
        var content: CGRect
        var canvas: CGSize
        var transform: Transform2D
    }

    private func setup(seed: Int) -> Setup {
        var g = SeededGenerator(seed: UInt64(seed) &+ 0x0431)
        let canvases: [CGSize] = [CGSize(width: 1920, height: 1080),
                                  CGSize(width: 1080, height: 1920),
                                  CGSize(width: 640, height: 360)]
        let canvas = canvases[g.int(in: 0...2)]
        return Setup(
            content: CGRect(x: g.double(in: 0...canvas.width * 0.8),
                            y: g.double(in: 0...canvas.height * 0.8),
                            width: g.double(in: 10...canvas.width * 0.9),
                            height: g.double(in: 10...canvas.height * 0.5)),
            canvas: canvas,
            transform: Transform2D(position: CGPoint(x: g.double(in: -1...1),
                                                     y: g.double(in: -1...1)),
                                   scale: g.double(in: 0.1...4),
                                   rotation: 0))
    }

    @Test("矩形と transform は行き来しても変わらない", arguments: 0..<300)
    func rectAndTransformRoundTrip(seed: Int) {
        let s = setup(seed: seed)
        let rect = OverlayLayout.rect(content: s.content, transform: s.transform, canvas: s.canvas)
        let back = OverlayLayout.transform(for: rect, content: s.content, canvas: s.canvas)
        #expect(abs(back.scale - s.transform.scale) < 1e-9)
        #expect(abs(back.position.x - s.transform.position.x) < 1e-9)
        #expect(abs(back.position.y - s.transform.position.y) < 1e-9)
    }

    /// これが崩れると、掴んだ枠と画面に出る字幕がずれる。
    @Test("ハンドルの枠と、描画に使う変換が同じ場所を指す", arguments: 0..<300)
    func handleRectMatchesWhatIsDrawn(seed: Int) {
        let s = setup(seed: seed)
        let rect = OverlayLayout.rect(content: s.content, transform: s.transform, canvas: s.canvas)
        let ci = OverlayLayout.ciTransform(content: s.content, transform: s.transform,
                                           canvas: s.canvas)
        // ラスタライズ結果は原点から content の大きさぶん。これを変換した先が
        // 描かれる位置になる。Core Image は左下原点なので y を戻して比べる。
        let drawn = CGRect(origin: .zero, size: s.content.size).applying(ci)
        #expect(abs(drawn.minX - rect.minX) < 1e-6,
                "左端が \(rect.minX) と \(drawn.minX) で食い違う")
        #expect(abs((s.canvas.height - drawn.maxY) - rect.minY) < 1e-6,
                "上端が \(rect.minY) と \(s.canvas.height - drawn.maxY) で食い違う")
        #expect(abs(drawn.width - rect.width) < 1e-6)
        #expect(abs(drawn.height - rect.height) < 1e-6)
    }

    @Test("倍率 1・位置ずれ無しなら、テンプレートの位置のまま", arguments: 0..<100)
    func identityKeepsTheTemplatePlacement(seed: Int) {
        let s = setup(seed: seed)
        let rect = OverlayLayout.rect(content: s.content,
                                      transform: Transform2D(position: .zero, scale: 1, rotation: 0),
                                      canvas: s.canvas)
        #expect(abs(rect.minX - s.content.minX) < 1e-9)
        #expect(abs(rect.minY - s.content.minY) < 1e-9)
        #expect(abs(rect.width - s.content.width) < 1e-9)
    }
}
