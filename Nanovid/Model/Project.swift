import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 素材

enum AssetKind: String, Codable, Hashable {
    case video, audio, image

    var label: String {
        switch self {
        case .video: return L("動画")
        case .audio: return L("音声")
        case .image: return L("画像")
        }
    }
}

/// 元ファイルへの参照のみを持つ。変換もコピーもしない（非破壊・テンポラリなし）。
struct MediaAsset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// プロジェクトファイルからの相対パス、または絶対パス。
    var path: String
    var displayName: String
    var kind: AssetKind
    /// 読み込み時にキャッシュしたメタデータ。再読込で更新される。
    var duration: Double
    var naturalSize: CGSize?
    var hasAudio: Bool
    var hasVideo: Bool
    /// App Sandbox の下で開き直したときに、この素材を読めるようにするための
    /// security-scoped bookmark。取り込んだときに作り、プロジェクトと一緒に保存する。
    /// 古いプロジェクトには無い（そのときは path だけで探す）。MediaAccess を参照。
    var bookmark: Data? = nil

    /// - Parameter base: プロジェクトファイルのあるディレクトリ。
    ///   URL(fileURLWithPath:relativeTo:) は base の末尾スラッシュの有無で
    ///   最後の要素を落としてしまうので、自前で連結する。
    func url(relativeTo base: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base else { return URL(fileURLWithPath: path).standardizedFileURL }
        var url = base
        for component in path.split(separator: "/") where component != "." {
            url.appendPathComponent(String(component))
        }
        return url.standardizedFileURL
    }
}

// MARK: - クリップ

enum ClipContent: Codable, Hashable {
    /// 素材の sourceStart から duration 秒ぶんを使う。
    case media(assetID: UUID, sourceStart: Double)
    case text(TextInstance)

    var assetID: UUID? { if case .media(let id, _) = self { return id }; return nil }
    var textInstance: TextInstance? { if case .text(let t) = self { return t }; return nil }
}

struct Clip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// タイムライン上の開始位置（秒）。
    var start: Double
    var duration: Double
    var content: ClipContent

    // 映像系
    var transform: Transform2D = .identity
    var opacity: Double = 1
    // 音声系
    var volume: Double = 1

    var fade: Fade = .none

    var end: Double { start + duration }
    var range: ClosedRange<Double> { start...(start + duration) }

    func contains(_ t: Double) -> Bool { t >= start && t < end }

    /// 指定時刻での実効不透明度（フェード込み）。
    func effectiveOpacity(at t: Double) -> Double {
        opacity * fade.factor(at: t - start, clipDuration: duration)
    }

    /// 指定時刻での実効音量（フェード込み）。
    func effectiveVolume(at t: Double) -> Double {
        volume * fade.factor(at: t - start, clipDuration: duration)
    }
}

// MARK: - トラック

enum TrackKind: String, Codable, Hashable {
    case video, audio

    var label: String {
        switch self {
        case .video: return L("映像")
        case .audio: return L("音声")
        }
    }
}

struct Track: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: TrackKind
    var isMuted: Bool = false
    var isHidden: Bool = false
    var isLocked: Bool = false
    /// start 昇順で保持する。
    var clips: [Clip] = []

    var duration: Double { clips.map(\.end).max() ?? 0 }

    mutating func sortClips() { clips.sort { $0.start < $1.start } }

    func clip(at time: Double) -> Clip? { clips.first { $0.contains(time) } }

    func clips(overlapping range: Range<Double>) -> [Clip] {
        clips.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
    }
}

// MARK: - プロジェクト

/// 書き出す範囲。開始と終了はそれぞれ独立に動かす。
struct OutputRange: Codable, Hashable {
    var start: Double
    var end: Double
}

struct Project: Codable, Hashable {
    var formatVersion: Int = 1
    var name: String = L("無題")
    var canvas: CanvasSpec = CanvasSpec()
    var assets: [MediaAsset] = []
    /// 配列の先頭が最背面。UI では上下反転して表示する。
    var tracks: [Track] = []
    var textTemplates: [TextTemplate] = []
    /// 書き出す範囲。nil のあいだはクリップの終端に追従する。
    /// 一度でも端を動かすと確定し、以後クリップを足しても勝手に伸びない。
    var outputRange: OutputRange?

    /// クリップが置かれている末尾。範囲とは別で、タイムラインの中身そのもの。
    var contentEnd: Double { tracks.map(\.duration).max() ?? 0 }

    /// 書き出す範囲の開始。
    var outputStart: Double { max(0, outputRange?.start ?? 0) }

    /// 書き出す範囲の終了。開始より前には来ない。
    var outputEnd: Double { max(outputStart, outputRange?.end ?? contentEnd) }

    /// 書き出される動画の尺。
    var duration: Double { max(0, outputEnd - outputStart) }

    /// 範囲を自分で決めているか。false ならクリップに追従している。
    var hasExplicitOutputRange: Bool { outputRange != nil }

    func isInsideOutput(_ time: Double) -> Bool {
        time >= outputStart - 1e-9 && time <= outputEnd + 1e-9
    }

    func asset(_ id: UUID) -> MediaAsset? { assets.first { $0.id == id } }
    func template(_ id: UUID) -> TextTemplate? { textTemplates.first { $0.id == id } }

    func track(containing clipID: UUID) -> Track? {
        tracks.first { $0.clips.contains { $0.id == clipID } }
    }

    func clip(_ id: UUID) -> Clip? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    /// 全トラックを横断して、指定テンプレートを使っているテキストクリップを集める。
    func textClips(usingTemplate templateID: UUID) -> [(trackID: UUID, clip: Clip)] {
        tracks.flatMap { track in
            track.clips.compactMap { clip in
                guard let inst = clip.content.textInstance, inst.templateID == templateID else { return nil }
                return (track.id, clip)
            }
        }
    }

    var allTextClips: [(trackID: UUID, clip: Clip)] {
        tracks.flatMap { track in
            track.clips.compactMap { clip in
                clip.content.textInstance == nil ? nil : (track.id, clip)
            }
        }
    }

    static func starter() -> Project {
        var p = Project()
        p.canvas = CanvasSpec(width: 1920, height: 1080, fps: 30)
        p.tracks = [
            Track(name: L("映像 1"), kind: .video),
            Track(name: L("テロップ"), kind: .video),
            Track(name: L("音声 1"), kind: .audio),
        ]
        p.textTemplates = [.subtitle(), .plainSubtitle(), .lowerLeftNote(), .title()]
        return p
    }
}

// MARK: - 書き出す範囲の切り出し

extension Project {

    /// 書き出す範囲の外を落としたプロジェクトを返す。時刻はそのまま。
    ///
    /// 範囲の先頭を 0 秒に寄せたほうが素直だが、そうすると
    /// AVAssetReader が -11841（不正な映像合成）で読み始めに失敗する。
    /// 先頭は 0 のまま、範囲外を空にして合成の手間だけ省く。
    /// 出力の頭出しは AVAssetWriter のセッション開始時刻でそろえる。
    func croppedToOutputRange() -> Project {
        let from = outputStart
        let to = outputEnd
        var copy = self
        copy.tracks = tracks.map { track in
            var cropped = track
            cropped.clips = track.clips.compactMap { clip in
                // 範囲にまったくかからないものだけを落とす。
                guard min(clip.end, to) - max(clip.start, from) > 1e-9 else { return nil }

                // 端を落とすのは、フェードが終わったあとでだけ。
                //
                // Fade はクリップの端からの長さしか持たないので、途中から始まる
                // フェードを表せない。フェードの最中で切ると、切った先から改めて
                // 0 から立ち上がってしまい、同じ時刻の見え方が変わる
                // （プレビューと書き出しが食い違う）。
                // 切らずに残しても、余分に描くのはフェードの長さぶんだけで済む。
                let wantHead = max(0, from - clip.start)
                let headCut = wantHead >= clip.fade.inDuration ? wantHead : 0
                let wantTail = max(0, clip.end - to)
                let tailCut = wantTail >= clip.fade.outDuration ? wantTail : 0

                var cut = clip
                cut.start = clip.start + headCut
                cut.duration = clip.duration - headCut - tailCut
                if case .media(let assetID, let sourceStart) = clip.content {
                    cut.content = .media(assetID: assetID, sourceStart: sourceStart + headCut)
                }
                // 落とした端のぶんフェードを縮める。上の条件から、縮むときは 0 になる。
                cut.fade = Fade(inDuration: max(0, clip.fade.inDuration - headCut),
                                outDuration: max(0, clip.fade.outDuration - tailCut))
                return cut
            }
            return cropped
        }
        return copy
    }
}
