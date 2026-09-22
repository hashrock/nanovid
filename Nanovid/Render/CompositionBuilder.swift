import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: Double
}

enum BuildError: LocalizedError {
    case emptyProject
    case assetMissing(String)
    case unreadable(String)
    /// この Mac にデコーダが無い。別の Mac で作ったプロジェクトを開くと起きうる。
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .emptyProject: return L("タイムラインに何も置かれていません。")
        case .assetMissing(let name): return L("素材が見つかりません: \(name)")
        case .unreadable(let name): return L("素材を読み込めません: \(name)")
        case .undecodable(let name): return L("「\(name)」はこの Mac で再生できない形式です。")
        }
    }
}

/// 使い回す合成トラックと、そこに詰め終わっている末尾時刻。
private struct TrackSlot {
    let track: AVMutableCompositionTrack
    var end: Double
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
        let canvasSize = canvas.size
        let composition = AVMutableComposition()

        var pending: [PendingLayer] = []
        // 合成トラックは使い回す。クリップごとに新規作成するとデコーダが際限なく増える。
        var videoPool: [TrackSlot] = []
        var audioPool: [TrackSlot] = []
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var z = 0

        for track in project.tracks where !track.isLocked {
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                z += 1
                switch clip.content {
                case .text(let instance):
                    guard track.kind == .video, !track.isHidden,
                          let template = project.template(instance.templateID) else { continue }
                    let props = instance.resolvedProps(in: template)
                    guard let raster = TextRasterizer.shared.rasterize(
                        template: template, props: props, canvas: canvasSize
                    ) else { continue }
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
                    let sourceRange = CMTimeRange(start: sourceStart.cmTime, duration: clip.duration.cmTime)

                    // 映像
                    if track.kind == .video, !track.isHidden,
                       let vTrack = try await av.loadTracks(withMediaType: .video).first,
                       let compTrack = claimTrack(in: &videoPool, mediaType: .video,
                                                  composition: composition, clip: clip) {
                        // 取り込み時にも見ているが、プロジェクトは別の Mac から来ることがある。
                        // AVPlayer は黙って黒を流すので、ここで言わないと誰も言わない。
                        guard try await vTrack.load(.isDecodable) else {
                            throw BuildError.undecodable(asset.displayName)
                        }
                        try compTrack.insertTimeRange(sourceRange, of: vTrack, at: clip.start.cmTime)
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
                                                  composition: composition, clip: clip) {
                        try compTrack.insertTimeRange(sourceRange, of: aTrack, at: clip.start.cmTime)
                        let params = audioParams[compTrack.trackID]
                            ?? AVMutableAudioMixInputParameters(track: compTrack)
                        applyVolume(clip: clip, to: params)
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
        try await insertSpacer(into: composition, upTo: end)

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
                alwaysRenders: constantFrameRate)
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
                                audioMix: mix, duration: end.secondsOrZero)
    }

    // MARK: - 土台トラック

    private static let blankAsset: AVURLAsset? = {
        guard let url = Bundle.main.url(forResource: "blank", withExtension: "mp4") else { return nil }
        return AVURLAsset(url: url)
    }()

    /// タイムライン全域をブランク素材で埋める。素材が尽きたら先頭から繰り返す。
    private static func insertSpacer(into composition: AVMutableComposition, upTo total: CMTime) async throws {
        guard let blank = blankAsset,
              let source = try await blank.loadTracks(withMediaType: .video).first,
              let spacer = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }

        let unit = try await blank.load(.duration)
        guard unit.isNumeric, unit.seconds > 0, total > .zero else { return }
        var cursor = CMTime.zero
        while cursor < total {
            let remaining = total - cursor
            let step = min(unit, remaining)
            try spacer.insertTimeRange(CMTimeRange(start: .zero, duration: step), of: source, at: cursor)
            cursor = cursor + step
        }
    }

    // MARK: - 補助

    /// 空いている合成トラックを探し、無ければ新設する。
    private static func claimTrack(in pool: inout [TrackSlot],
                                   mediaType: AVMediaType,
                                   composition: AVMutableComposition,
                                   clip: Clip) -> AVMutableCompositionTrack? {
        if let index = pool.firstIndex(where: { $0.end <= clip.start + 1e-6 }) {
            pool[index].end = clip.end
            return pool[index].track
        }
        guard let made = composition.addMutableTrack(
            withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        pool.append(TrackSlot(track: made, end: clip.end))
        return made
    }

    /// クリップ単位の音量とフェードを AVAudioMix のパラメータへ積む。
    private static func applyVolume(clip: Clip, to p: AVMutableAudioMixInputParameters) {
        let v = Float(clip.volume)
        p.setVolume(v, at: clip.start.cmTime)

        if clip.fade.inDuration > 0 {
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v,
                            timeRange: CMTimeRange(start: clip.start.cmTime,
                                                   duration: clip.fade.inDuration.cmTime))
        }
        if clip.fade.outDuration > 0 {
            let s = clip.end - clip.fade.outDuration
            p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0,
                            timeRange: CMTimeRange(start: s.cmTime,
                                                   duration: clip.fade.outDuration.cmTime))
        }
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
