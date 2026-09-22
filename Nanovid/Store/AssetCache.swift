import AVFoundation
import Foundation

/// 素材として使えない理由。取り込みの時点で言う。
///
/// AVPlayer は対応外のコーデックでも readyToPlay を返し、途中で切れたファイルでも
/// 最後まで時間を進める。どちらも画は黒いまま、エラーはひとつも出ない。
/// あとから気づく手立てが無いので、ここで実際にデコードを試して弾く。
enum MediaProblem: LocalizedError {
    case undecodable(name: String, codec: String)
    case truncated(name: String)

    var errorDescription: String? {
        switch self {
        case .undecodable(let name, let codec):
            return L("「\(name)」はこの Mac で再生できない形式です（\(codec)）。H.264 や HEVC の MP4 / MOV に変換してから読み込んでください。")
        case .truncated(let name):
            return L("「\(name)」は最後まで読めません。ファイルが途中で切れているかもしれません。")
        }
    }
}

/// URL ごとに AVURLAsset を使い回す。編集のたびにメタデータを読み直さないための土台。
final class AssetCache {
    static let shared = AssetCache()

    private let lock = NSLock()
    private var assets: [String: AVURLAsset] = [:]

    private init() {}

    func asset(for url: URL) -> AVURLAsset {
        let key = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if let hit = assets[key] { return hit }
        let made = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        assets[key] = made
        return made
    }

    func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        assets.removeValue(forKey: url.standardizedFileURL.path)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        assets.removeAll()
    }

    /// ファイルを読み込んで MediaAsset のメタデータを埋める。
    func inspect(url: URL) async throws -> MediaAsset {
        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"]

        if imageExtensions.contains(ext) {
            let size = ImageProbe.size(of: url) ?? CGSize(width: 1920, height: 1080)
            return MediaAsset(path: url.path, displayName: url.deletingPathExtension().lastPathComponent,
                              kind: .image, duration: 5, naturalSize: size,
                              hasAudio: false, hasVideo: false)
        }

        let av = asset(for: url)
        let duration = try await av.load(.duration).secondsOrZero
        let videoTracks = try await av.loadTracks(withMediaType: .video)
        let audioTracks = try await av.loadTracks(withMediaType: .audio)
        let name = url.deletingPathExtension().lastPathComponent

        for track in videoTracks + audioTracks where try await !track.load(.isDecodable) {
            throw MediaProblem.undecodable(name: name, codec: try await Self.codecName(of: track))
        }

        var size: CGSize?
        if let v = videoTracks.first {
            let natural = try await v.load(.naturalSize)
            let transform = try await v.load(.preferredTransform)
            size = natural.applying(transform).standardizedSize
            // 末尾のフレームを実際に 1 枚読む。途中で切れたファイルは isDecodable では分からない。
            try await Self.probeTail(of: av, duration: duration, name: name)
        }
        let kind: AssetKind = videoTracks.isEmpty ? .audio : .video
        return MediaAsset(path: url.path,
                          displayName: url.deletingPathExtension().lastPathComponent,
                          kind: kind, duration: duration, naturalSize: size,
                          hasAudio: !audioTracks.isEmpty, hasVideo: !videoTracks.isEmpty)
    }
}

extension AssetCache {

    /// 末尾付近のフレームを 1 枚読んでみる。読めなければ切れている。
    /// 先頭は読めるのに末尾で転ぶのが、途中で切れたファイルの典型。
    static func probeTail(of asset: AVURLAsset, duration: Double, name: String) async throws {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        // ちょうどの位置にこだわらない。直前のキーフレームから復号できれば十分。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 64, height: 64)
        let near = max(0, duration - 0.1).cmTime
        do {
            _ = try await generator.image(at: near)
        } catch {
            throw MediaProblem.truncated(name: name)
        }
    }

    /// 表示用のコーデック名（"vp09" のような 4 文字）。
    static func codecName(of track: AVAssetTrack) async throws -> String {
        guard let description = try await track.load(.formatDescriptions).first else { return L("不明") }
        let sub = CMFormatDescriptionGetMediaSubType(description)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((sub >> $0) & 0xff))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

extension CGSize {
    /// 回転変形で負になった辺を正に戻す。
    var standardizedSize: CGSize { CGSize(width: abs(width), height: abs(height)) }
}

enum ImageProbe {
    static func size(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }
}
