import AVFoundation
import AVKit
import SwiftUI

/// AVPlayerLayer をそのまま出すだけの軽量プレビュー。
/// 合成はカスタムコンポジタ側で完結しているので、ここは表示に徹する。
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerContainerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// キャンバス比を保った枠にプレビューを収める。
/// 選んでいる映像・画像には枠とハンドルを出して、その場で動かせるようにする。
struct PreviewPane: View {
    @Bindable var store: EditorStore

    /// ハンドルのドラッグを測る座標空間。ハンドル自身は動くので、
    /// ジェスチャ既定のローカル空間で測ると位置が振動する。
    private static let spaceName = "nanovid.preview.canvas"

    @State private var drag: HandleDrag?

    var body: some View {
        GeometryReader { geo in
            let aspect = store.project.canvas.aspectRatio
            let available = geo.size
            let fitted = fit(aspect: aspect, in: available)
            ZStack {
                Color.black.opacity(0.35)
                PlayerLayerView(player: store.player)
                    // 書き出す範囲の外では AVPlayer が端のフレームに張り付くので隠す。
                    // 背景色だけが残り、書き出したときと同じ「何も無い」状態になる。
                    .opacity(store.isOutsideOutput ? 0 : 1)
                    .frame(width: fitted.width, height: fitted.height)
                    .background(Color(store.project.canvas.backgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                if let target = editTarget {
                    handles(for: target, box: fitted)
                        .frame(width: fitted.width, height: fitted.height)
                        .coordinateSpace(.named(Self.spaceName))
                }

                if store.project.contentEnd <= 0 {
                    Text("タイムラインに素材かテキストを追加してください")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if store.isOutsideOutput {
                    // 範囲の外では AVPlayer が端のフレームに張り付くので、
                    // そのままだと「まだ中身がある」ように見えてしまう。
                    Text("書き出す範囲の外です")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(width: fitted.width, height: fitted.height,
                               alignment: .bottom)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: available.width, height: available.height)
        }
    }

    // MARK: - 直接操作

    /// いま枠を出す対象。1 つだけ選んでいて、その時刻に映っているもの。
    private struct EditTarget {
        enum Content {
            /// 映像や画像。素材の中心を動かす。
            case media(naturalSize: CGSize)
            /// テキスト。テンプレートが決めた位置を土台にする。
            case text(content: CGRect)
        }
        var clip: Clip
        var content: Content
    }

    private var editTarget: EditTarget? {
        guard store.selectedClipIDs.count == 1,
              let id = store.selectedClipIDs.first,
              let clip = store.project.clip(id),
              clip.contains(store.currentTime),
              let track = store.project.track(containing: id),
              !track.isHidden, !track.isLocked
        else { return nil }

        if let instance = clip.content.textInstance {
            guard let template = store.project.template(instance.templateID),
                  let raster = TextRasterizer.shared.rasterize(
                      template: template,
                      props: instance.resolvedProps(in: template),
                      canvas: store.project.canvas.size),
                  raster.rect.width > 0
            else { return nil }
            return EditTarget(clip: clip, content: .text(content: raster.rect))
        }

        guard let assetID = clip.content.assetID,
              let asset = store.project.asset(assetID),
              asset.kind != .audio,
              let size = asset.naturalSize,
              size.width > 0, size.height > 0
        else { return nil }
        return EditTarget(clip: clip, content: .media(naturalSize: size))
    }

    /// キャンバス座標での配置矩形。種類ごとに計算のしかたが違う。
    private func canvasRect(of target: EditTarget, transform: Transform2D) -> CGRect {
        let canvas = store.project.canvas.size
        switch target.content {
        case .media(let size):
            return MediaLayout.rect(naturalSize: size, transform: transform, canvas: canvas)
        case .text(let content):
            return OverlayLayout.rect(content: content, transform: transform, canvas: canvas)
        }
    }

    /// 動かした結果の矩形から transform を逆に求める。
    private func transform(of target: EditTarget, for rect: CGRect, rotation: Double) -> Transform2D {
        let canvas = store.project.canvas.size
        switch target.content {
        case .media(let size):
            return MediaLayout.transform(for: rect, naturalSize: size,
                                         canvas: canvas, rotation: rotation)
        case .text(let content):
            return OverlayLayout.transform(for: rect, content: content,
                                           canvas: canvas, rotation: rotation)
        }
    }

    /// これより小さくはしない幅。
    private func minimumWidth(of target: EditTarget) -> Double {
        let canvas = store.project.canvas.size
        switch target.content {
        case .media(let size):
            return size.width * MediaLayout.fitScale(size, in: canvas) * 0.02
        case .text(let content):
            return content.width * 0.1
        }
    }

    struct HandleDrag {
        enum Kind: Equatable {
            case move
            case corner(MediaLayout.Corner)
        }
        var clipID: UUID
        var kind: Kind
        var startTransform: Transform2D
        /// 掴んだ瞬間のキャンバス座標での矩形。以降はこれを基準に計算する。
        var startRect: CGRect
    }

    @ViewBuilder
    private func handles(for target: EditTarget, box: CGSize) -> some View {
        let canvas = store.project.canvas.size
        let scale = box.width / canvas.width
        let rect = canvasRect(of: target, transform: target.clip.transform)
        let frame = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                           width: rect.width * scale, height: rect.height * scale)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .offset(x: frame.minX, y: frame.minY)
                .onHover { inside in
                    if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
                .gesture(moveGesture(target: target, scale: scale))

            ForEach(MediaLayout.Corner.allCases, id: \.self) { corner in
                handle(corner, in: frame, target: target, scale: scale)
            }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
    }

    private func handle(_ corner: MediaLayout.Corner, in frame: CGRect,
                        target: EditTarget, scale: Double) -> some View {
        let point = corner.point(in: frame)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .offset(x: point.x - 5.5, y: point.y - 5.5)
            .onHover { inside in
                if inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
            .gesture(resizeGesture(corner: corner, target: target, scale: scale))
    }

    private func moveGesture(target: EditTarget, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                let canvas = store.project.canvas.size
                let started = begin(target, kind: .move, scale: scale)
                let dx = Double(value.location.x - value.startLocation.x) / scale
                let dy = Double(value.location.y - value.startLocation.y) / scale
                var transform = started.startTransform
                transform.position = CGPoint(
                    x: started.startTransform.position.x + dx / canvas.width,
                    y: started.startTransform.position.y + dy / canvas.height)
                apply(transform, to: target.clip.id)
            }
            .onEnded { _ in drag = nil }
    }

    private func resizeGesture(corner: MediaLayout.Corner,
                               target: EditTarget, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                let started = begin(target, kind: .corner(corner), scale: scale)
                // 画面上の位置をキャンバス座標へ直してから計算する。
                let point = CGPoint(x: Double(value.location.x) / scale,
                                    y: Double(value.location.y) / scale)
                let resized = MediaLayout.resized(started.startRect, corner: corner, to: point,
                                                  minimumWidth: minimumWidth(of: target))
                apply(transform(of: target, for: resized,
                                rotation: started.startTransform.rotation),
                      to: target.clip.id)
            }
            .onEnded { _ in drag = nil }
    }

    /// 掴んだ瞬間の状態を覚える。以降はここを基準にするので、
    /// 枠が動いても結果が変わらない。
    private func begin(_ target: EditTarget, kind: HandleDrag.Kind, scale: Double) -> HandleDrag {
        if let drag, drag.clipID == target.clip.id, drag.kind == kind { return drag }
        let started = HandleDrag(
            clipID: target.clip.id,
            kind: kind,
            startTransform: target.clip.transform,
            startRect: canvasRect(of: target, transform: target.clip.transform))
        drag = started
        return started
    }

    private func apply(_ transform: Transform2D, to clipID: UUID) {
        store.updateClip(clipID, coalesceKey: "transform:\(clipID)") { $0.transform = transform }
    }

    private func fit(aspect: Double, in size: CGSize) -> CGSize {
        let padding: Double = 8
        let w = max(1, size.width - padding * 2)
        let h = max(1, size.height - padding * 2)
        if w / h > aspect {
            return CGSize(width: h * aspect, height: h)
        } else {
            return CGSize(width: w, height: w / aspect)
        }
    }
}
