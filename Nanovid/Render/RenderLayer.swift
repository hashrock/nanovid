import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// 1 セグメント内で合成する 1 枚のレイヤー。背面から前面の順で並ぶ。
struct RenderLayer {
    enum Source {
        /// AVComposition 内の映像トラック。
        case media(trackID: CMPersistentTrackID, preferredTransform: CGAffineTransform)
        /// 事前にラスタライズ済みのテキスト。rect はキャンバス座標（左上原点）。
        case text(image: CGImage, rect: CGRect)
    }

    var source: Source
    /// タイムライン上のクリップ範囲。フェード計算に使う。
    var clipStart: Double
    var clipDuration: Double
    var transform: Transform2D
    var opacity: Double
    var fade: Fade

    func alpha(at time: Double) -> Double {
        opacity * fade.factor(at: time - clipStart, clipDuration: clipDuration)
    }

    var trackID: CMPersistentTrackID? {
        if case .media(let id, _) = source { return id }
        return nil
    }
}

/// カスタムコンポジタへ渡す命令。区間ごとに「その時間に見えるレイヤー一覧」を持つ。
final class NanovidInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [RenderLayer]
    let backgroundColor: RGBAColor
    let canvasSize: CGSize

    init(timeRange: CMTimeRange, layers: [RenderLayer], backgroundColor: RGBAColor, canvasSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self.backgroundColor = backgroundColor
        self.canvasSize = canvasSize
        self.containsTweening = layers.contains { $0.fade.inDuration > 0 || $0.fade.outDuration > 0 }
        let ids = layers.compactMap(\.trackID).map { NSNumber(value: $0) as NSValue }
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids
        super.init()
    }
}
