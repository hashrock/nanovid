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
                    // 尺の先では AVPlayer が末尾のフレームに張り付くので隠す。
                    // 背景色だけが残り、書き出したときと同じ「何も無い」状態になる。
                    .opacity(store.isPastEnd ? 0 : 1)
                    .frame(width: fitted.width, height: fitted.height)
                    .background(Color(store.project.canvas.backgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                if store.project.duration <= 0 {
                    Text("タイムラインに素材かテキストを追加してください")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if store.isPastEnd {
                    // 尺を超えた位置では AVPlayer が末尾のフレームに張り付くので、
                    // そのままだと「まだ中身がある」ように見えてしまう。
                    Text("ここから先は空です")
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
