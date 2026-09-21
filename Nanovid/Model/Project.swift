import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 素材

enum AssetKind: String, Codable, Hashable {
    case video, audio, image

    var label: String {
        switch self {
        case .video: return "動画"
        case .audio: return "音声"
        case .image: return "画像"
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
        case .video: return "映像"
        case .audio: return "音声"
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

struct Project: Codable, Hashable {
    var formatVersion: Int = 1
    var name: String = "無題"
    var canvas: CanvasSpec = CanvasSpec()
    var assets: [MediaAsset] = []
    /// 配列の先頭が最背面。UI では上下反転して表示する。
    var tracks: [Track] = []
    var textTemplates: [TextTemplate] = []

    var duration: Double { tracks.map(\.duration).max() ?? 0 }

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
            Track(name: "映像 1", kind: .video),
            Track(name: "テロップ", kind: .video),
            Track(name: "音声 1", kind: .audio),
        ]
        p.textTemplates = [.subtitle(), .title()]
        return p
    }
}
