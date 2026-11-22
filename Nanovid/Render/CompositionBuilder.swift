import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os

let renderLog = Logger(subsystem: "nanovid", category: "render")

/// 置いてあるのに描かれないクリップ。非表示のトラックのように、わざと描かないものは含めない。
struct SkippedClip: Codable, Hashable {
    var clipID: UUID
    var name: String
    var reason: String
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: Double
    /// 描けずに外したクリップ。「文字が消えた」の手がかりにする。
    var skipped: [SkippedClip] = []
}

enum BuildError: LocalizedError {
    case emptyProject
    case invalidCanvas
    case assetMissing(String)
    case unreadable(String)
    /// この Mac にデコーダが無い。別の Mac で作ったプロジェクトを開くと起きうる。
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .emptyProject: return L("タイムラインに何も置かれていません。")
        case .invalidCanvas: return L("キャンバスの設定が正しくありません。")
        case .assetMissing(let name): return L("素材が見つかりません: \(name)")
        case .unreadable(let name): return L("素材を読み込めません: \(name)")
        case .undecodable(let name): return L("「\(name)」はこの Mac で再生できない形式です。")
        }
    }
}

/// 使い回す合成トラックと、そこに詰め終わっている末尾時刻。
/// insertTimeRange が使う CMTime 基準で持つ。Double で比べると 1/600 秒の丸め差で
/// 既存区間の内側へ割り込んでしまい、後ろの区間が押し出されることがある。
private struct TrackSlot {
    let track: AVMutableCompositionTrack
    var end: CMTime
}

/// 区間分割前の中間表現。
private struct PendingLayer {
    var source: RenderLayer.Source
    var start: Double
    var duration: Double
    var transform: Transform2D
    var opacity: Double
    var fade: Fade
    /// 重なり順。小さいほど背面。
    var z: Int
}

/// Project（編集モデル）を AVFoundation の再生・書き出し用オブジェクトへ変換する。
/// 元ファイルを参照するだけで、中間ファイルは一切作らない。
enum CompositionBuilder {

    /// - Parameter constantFrameRate: 静止した区間でも毎フレーム描く。書き出し用。
    static func build(project: Project, baseURL: URL?,
                      constantFrameRate: Bool = false) async throws -> BuiltComposition {
        let canvas = project.canvas
        guard canvas.width > 0, canvas.height > 0, canvas.fps > 0 else {
            throw BuildError.invalidCanvas
        }
        let canvasSize = canvas.size
        let composition = AVMutableComposition()

        var pending: [PendingLayer] = []
        // 合成トラックは使い回す。クリップごとに新規作成するとデコーダが際限なく増える。
        var videoPool: [TrackSlot] = []
        var audioPool: [TrackSlot] = []
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var z = 0
        var skipped: [SkippedClip] = []
        func skip(_ clip: Clip, _ reason: String) {
            skipped.append(SkippedClip(clipID: clip.id, name: clip.name, reason: reason))
            renderLog.notice("クリップ「\(clip.name, privacy: .public)」を描かない: \(reason, privacy: .public)")
        }

        // ロックは「編集できない」だけ。描画からは外さない。
        for track in project.tracks {
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                z += 1
                switch clip.content {
                case .text(let instance):
                    guard track.kind == .video, !track.isHidden else { continue }
                    guard let template = project.template(instance.templateID) else {
                        skip(clip, "テンプレートが見つからない")
                        continue
                    }
                    let props = instance.resolvedProps(in: template)
                    guard let raster = TextRasterizer.shared.rasterize(
                        template: template, props: props, canvas: canvasSize
                    ) else {
                        skip(clip, "描くものが無い（文字が空・ノードが全部非表示・キャンバスから遠く外れている）")
                        continue
                    }
                    pending.append(PendingLayer(
                        source: .text(image: raster.image, rect: raster.rect),
                        start: clip.start, duration: clip.duration,
                        transform: clip.transform, opacity: clip.opacity, fade: clip.fade, z: z
                    ))

                case .media(let assetID, let sourceStart):
                    guard let asset = project.asset(assetID) else {
                        throw BuildError.assetMissing(L("(不明な素材)"))
                    }
                    let url = asset.url(relativeTo: baseURL)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw BuildError.assetMissing(asset.displayName)
                    }

                    if asset.kind == .image {
                        guard track.kind == .video, !track.isHidden else { continue }
                        guard let cg = loadImage(url) else { throw BuildError.unreadable(asset.displayName) }
                        pending.append(PendingLayer(
                            source: .still(image: cg),
                            start: clip.start, duration: clip.duration,
                            transform: clip.transform, opacity: clip.opacity, fade: clip.fade, z: z
                        ))
                        continue
                    }

                    let av = AssetCache.shared.asset(for: url)
                    guard clip.duration > 0 else { continue }
                    let clipStart = max(0, clip.start).cmTime
                    let clipDuration = clip.duration.cmTime
                    guard clipDuration > .zero else { continue }
                    let sourceRange = CMTimeRange(start: sourceStart.cmTime, duration: clipDuration)

                    // 映像
                    if track.kind == .video, !track.isHidden,
                       let vTrack = try await av.loadTracks(withMediaType: .video).first,
                       let compTrack = claimTrack(in: &videoPool, mediaType: .video,
                                                  composition: composition,
                                                  start: clipStart, duration: clipDuration) {
                        // 取り込み時にも見ているが、プロジェクトは別の Mac から来ることがある。
                        // AVPlayer は黙って黒を流すので、ここで言わないと誰も言わない。
                        guard try await vTrack.load(.isDecodable) else {
                            throw BuildError.undecodable(asset.displayName)
                        }
                        try compTrack.insertTimeRange(sourceRange, of: vTrack, at: clipStart)
                        let preferred = try await vTrack.load(.preferredTransform)
                        pending.append(PendingLayer(
                            source: .media(trackID: compTrack.trackID, preferredTransform: preferred),
                            start: clip.start, duration: clip.duration,
                            transform: clip.transform, opacity: clip.opacity, fade: clip.fade, z: z
                        ))
                    }

                    // 音声（映像トラックに置いたクリップの音もそのまま鳴らす）
                    if !track.isMuted, clip.volume > 0,
                       let aTrack = try await av.loadTracks(withMediaType: .audio).first,
                       let compTrack = claimTrack(in: &audioPool, mediaType: .audio,
                                                  composition: composition,
                                                  start: clipStart, duration: clipDuration) {
                        try compTrack.insertTimeRange(sourceRange, of: aTrack, at: clipStart)
                        let params = audioParams[compTrack.trackID]
                            ?? AVMutableAudioMixInputParameters(track: compTrack)
                        applyVolume(clip: clip, start: clipStart, duration: clipDuration, to: params)
                        audioParams[compTrack.trackID] = params
                    }
                }
            }
        }

        // 合成はタイムライン全体を持つ。書き出す範囲で切るのは Exporter の仕事。
        // 範囲をクリップの先まで伸ばしてあるときは、そこまで背景を敷く。
        let timelineDuration = max(max(project.contentEnd, project.outputEnd),
                                   composition.duration.secondsOrZero)
        guard timelineDuration > 0 else { throw BuildError.emptyProject }

        // 素材を入れ終わった時点での終端。Double へ落とすと端が丸められることがあるので、
        // 合成そのものの尺と突き合わせて長いほうを採る。
        let end = max(timelineDuration.cmTime, composition.duration)

        // 映像パイプラインを回すための土台。空のトラックではフレームが供給されず
        // 出力が途切れるので、同梱の極小ブランク素材をタイムライン全域に敷く。
        // レイヤーとしては合成しないので見た目には現れない。
        let spacerTrackID = try await insertSpacer(into: composition, upTo: end)

        // MARK: 区間分割（レイヤー構成が変わる時刻で切る）
        let plan = InstructionPlan.segments(
            for: pending.map { PlannedLayer(start: $0.start, duration: $0.duration, z: $0.z) },
            end: end)
        let instructions = plan.map { segment in
            let active = segment.layerIndices.map { i -> RenderLayer in
                let layer = pending[i]
                return RenderLayer(source: layer.source,
                                   clipStart: layer.start, clipDuration: layer.duration,
                                   transform: layer.transform, opacity: layer.opacity,
                                   fade: layer.fade)
            }
            return NanovidInstruction(
                timeRange: segment.range, layers: active,
                backgroundColor: canvas.backgroundColor, canvasSize: canvasSize,
                alwaysRenders: constantFrameRate, spacerTrackID: spacerTrackID)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = NanovidCompositor.self
        videoComposition.renderSize = canvasSize
        videoComposition.renderScale = 1
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(canvas.fps))
        videoComposition.instructions = instructions

        var mix: AVMutableAudioMix?
        if !audioParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = Array(audioParams.values)
            mix = m
        }

        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                audioMix: mix, duration: end.secondsOrZero, skipped: skipped)
    }

    // MARK: - 土台トラック

    private static let blankAsset: AVURLAsset? = {
        guard let url = Bundle.main.url(forResource: "blank", withExtension: "mp4") else { return nil }
        return AVURLAsset(url: url)
    }()

    /// タイムライン全域をブランク素材で埋める。素材が尽きたら先頭から繰り返す。
    /// - Returns: 敷いたトラックの ID。敷けなかったら nil。
    @discardableResult
    private static func insertSpacer(into composition: AVMutableComposition,
                                     upTo total: CMTime) async throws -> CMPersistentTrackID? {
        guard let blank = blankAsset,
              let source = try await blank.loadTracks(withMediaType: .video).first,
              let spacer = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            renderLog.error("土台のブランク素材を敷けない。文字だけの区間が描かれないことがある")
            return nil
        }

        let unit = try await blank.load(.duration)
        guard unit.isNumeric, unit.seconds > 0, total > .zero else {
            composition.removeTrack(spacer)
            return nil
        }
        var cursor = CMTime.zero
        while cursor < total {
            let remaining = total - cursor
            let step = min(unit, remaining)
            try spacer.insertTimeRange(CMTimeRange(start: .zero, duration: step), of: source, at: cursor)
            cursor = cursor + step
        }
        return spacer.trackID
    }

    // MARK: - 補助

    /// 空いている合成トラックを探し、無ければ新設する。
    private static func claimTrack(in pool: inout [TrackSlot],
                                   mediaType: AVMediaType,
                                   composition: AVMutableComposition,
                                   start: CMTime,
                                   duration: CMTime) -> AVMutableCompositionTrack? {
        let end = start + duration
        if let index = pool.firstIndex(where: { $0.end <= start }) {
            pool[index].end = end
            return pool[index].track
        }
        guard let made = composition.addMutableTrack(
            withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        pool.append(TrackSlot(track: made, end: end))
        return made
    }

    /// クリップ単位の音量とフェードを AVAudioMix のパラメータへ積む。
    ///
    /// AVAudioMix はランプの区間が少しでも重なると Obj-C 例外（NSInvalidArgumentException）で
    /// プロセスごと落ちる。フェードの和を尺へ収めたうえで、CMTime 上でも重ならないように切る。
    private static func applyVolume(clip: Clip,
                                    start clipStart: CMTime,
                                    duration clipDuration: CMTime,
                                    to p: AVMutableAudioMixInputParameters) {
        let clipEnd = clipStart + clipDuration
        guard clipEnd > clipStart else { return }
        let v = Float(max(0, clip.volume))
        p.setVolume(v, at: clipStart)

        let fade = clip.fade.clamped(to: clip.duration)
        var inEnd = clipStart
        if fade.inDuration > 0 {
            let dur = min(fade.inDuration.cmTime, clipDuration)
            if dur > .zero {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v,
                                timeRange: CMTimeRange(start: clipStart, duration: dur))
                inEnd = clipStart + dur
            }
        }
        if fade.outDuration > 0 {
            let outStart = max(inEnd, clipEnd - fade.outDuration.cmTime)
            let dur = clipEnd - outStart
            if dur > .zero {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0,
                                timeRange: CMTimeRange(start: outStart, duration: dur))
            }
        }
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(
                  src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return orient(raw, orientation)
    }

    /// EXIF Orientation をピクセルへ焼き込んで正立画像にする。
    /// そのまま渡すと iPhone の縦写真などが横向きや逆さまに描かれてしまう。
    private static func orient(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swapped: Bool
        let transform: CGAffineTransform
        switch orientation {
        case .up:
            return image
        case .upMirrored:
            swapped = false
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down:
            swapped = false
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored:
            swapped = false
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored:
            swapped = true
            transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right:
            swapped = true
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored:
            swapped = true
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:
            swapped = true
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        let outW = Int(swapped ? h : w)
        let outH = Int(swapped ? w : h)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
