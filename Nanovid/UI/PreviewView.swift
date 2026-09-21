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
struct PreviewPane: View {
    @Bindable var store: EditorStore

    var body: some View {
        GeometryReader { geo in
            let aspect = store.project.canvas.aspectRatio
            let available = geo.size
            let fitted = fit(aspect: aspect, in: available)
            ZStack {
                Color.black.opacity(0.35)
                PlayerLayerView(player: store.player)
                    .frame(width: fitted.width, height: fitted.height)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                if store.project.duration <= 0 {
                    Text("タイムラインに素材かテキストを追加してください")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: available.width, height: available.height)
        }
    }

    private func fit(aspect: Double, in size: CGSize) -> CGSize {
        let padding: Double = 16
        let w = max(1, size.width - padding * 2)
        let h = max(1, size.height - padding * 2)
        if w / h > aspect {
            return CGSize(width: h * aspect, height: h)
        } else {
            return CGSize(width: w, height: w / aspect)
        }
    }
}
