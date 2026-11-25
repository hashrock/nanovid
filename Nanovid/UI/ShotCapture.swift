#if DEBUG
import AppKit
import AVFoundation

/// スクリーンショット用（デバッグビルドだけ）。窓を画面の倍率によらず 2 倍の画素で描く。
/// 等倍の画面でも App Store の大きさ（2880×1800）に足りる絵を作るため。
///
/// `cacheDisplay` は AVPlayerLayer の映像を描かないので、プレビューにはその時刻の絵を
/// FrameRenderer で 2 倍のキャンバスに描いて、プレイヤーの層の上に一時的に重ねる。
/// 見えている窓（シート・開いたメニューを含む）を 1 枚ずつ書き、位置を windows.json に残す。
/// 撮影用のメニュー項目の受け手。選ばれても何もしない。
final class ShotMenuTarget: NSObject {
    static let shared = ShotMenuTarget()
    /// メニューの下敷きの窓（撮り終えるまで持っておく）。
    @MainActor static var backdrop: NSWindow?
    @objc func noop() {}
}

enum ShotCapture {
    @MainActor
    static func write(to dir: URL, store: EditorStore) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let overlay = await previewOverlay(store: store)
        defer { overlay?.removeFromSuperlayer() }

        var entries: [[String: Any]] = []
        for (n, window) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard bounds.width > 40, bounds.height > 20,
                  let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            let file = dir.appendingPathComponent("v\(n).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            entries.append(["file": file.path, "class": String(describing: type(of: window)),
                            "x": window.frame.minX, "y": window.frame.minY,
                            "w": window.frame.width, "h": window.frame.height,
                            "level": window.level.rawValue, "order": window.orderedIndex,
                            "main": window.isMainWindow || window.sheetParent == nil && window.level == .normal])
        }
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted) {
            try? data.write(to: dir.appendingPathComponent("windows.json"))
        }
    }

    /// プレイヤーの層の上に、今の時刻の絵（2 倍のキャンバス）を重ねる。
    @MainActor
    private static func previewOverlay(store: EditorStore) async -> CALayer? {
        guard let container = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(findPlayer) }).first
        else { return nil }
        var project = store.project
        project.canvas.width *= 2
        project.canvas.height *= 2
        guard let renderer = try? await FrameRenderer.make(project: project, baseURL: store.baseURL),
              let image = try? renderer.renderDirect(at: store.currentTime, sources: .decoded)
        else { return nil }
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.frame = container.bounds
        container.layer?.addSublayer(layer)
        return layer
    }

    @MainActor
    private static func findPlayer(in view: NSView) -> NSView? {
        if view is PlayerLayerView.PlayerContainerView { return view }
        for sub in view.subviews {
            if let hit = findPlayer(in: sub) { return hit }
        }
        return nil
    }
}
#endif

