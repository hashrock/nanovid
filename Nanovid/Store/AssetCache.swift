import AVFoundation
import Foundation

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
        var size: CGSize?
        if let v = videoTracks.first {
            let natural = try await v.load(.naturalSize)
            let transform = try await v.load(.preferredTransform)
            size = natural.applying(transform).standardizedSize
        }
        let kind: AssetKind = videoTracks.isEmpty ? .audio : .video
        return MediaAsset(path: url.path,
                          displayName: url.deletingPathExtension().lastPathComponent,
                          kind: kind, duration: duration, naturalSize: size,
                          hasAudio: !audioTracks.isEmpty, hasVideo: !videoTracks.isEmpty)
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
