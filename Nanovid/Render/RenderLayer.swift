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
        /// 静止画。映像と同じく「キャンバスに収める」基準で置く。
        case still(image: CGImage)
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

    /// - Parameters:
    ///   - alwaysRenders: 中身が動かない区間でも毎フレーム描かせる。
    ///     containsTweening が false だと「同じ素材フレームなら同じ絵」と見なされ、
    ///     素材が変わらない間は描き直しを省かれうる（文字だけの区間なら 1 枚で済む）。
    ///     再生はそれでよいが、書き出すとフレーム数が中身次第になってしまう
    ///     （静止した 1 秒が 1 枚になり、尺まで狂う）ので、書き出し時は true にする。
    ///     映像のレイヤーは素材のフレームが進むたびに描き直されるので、false でも止まらない。
    ///   - spacerTrackID: 土台のブランク素材のトラック。映像の無い区間ではこれだけを頼む。
    ///     nil を渡すと AVFoundation は全トラックのフレームを用意するので、
    ///     見えていない素材までデコードしてしまう。
    init(timeRange: CMTimeRange, layers: [RenderLayer], backgroundColor: RGBAColor,
         canvasSize: CGSize, alwaysRenders: Bool = false,
         spacerTrackID: CMPersistentTrackID? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.backgroundColor = backgroundColor
        self.canvasSize = canvasSize
        self.containsTweening = alwaysRenders
            || layers.contains { $0.fade.inDuration > 0 || $0.fade.outDuration > 0 }
        var ids = layers.compactMap(\.trackID)
        if ids.isEmpty, let spacerTrackID { ids = [spacerTrackID] }
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) as NSValue }
        super.init()
    }
}
