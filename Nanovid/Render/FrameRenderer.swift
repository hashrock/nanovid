import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// 1 コマ描くための共通の入口。テスト・`--render`・`--inspect`・MCP がここを通る。
///
/// 描き方は 2 つある。
/// - `direct`: 自前の合成（NanovidCompositor）を直に呼ぶ。AVFoundation の
///   スケジューリングや再生経路を通らない。
/// - `player`: AVAssetImageGenerator に合成を渡して描かせる。プレビュー・書き出しと
///   同じく、AVFoundation がコンポジタへフレームを頼む経路を通る。
///
/// 同じ時刻を両方で描いて比べれば、ずれの原因が自前の合成か AVFoundation 側かを切り分けられる。
final class FrameRenderer {

    enum Path: String, CaseIterable {
        case direct, player
    }

    /// `direct` で描くときの素材フレームの出どころ。
    enum Sources: String, CaseIterable {
        /// 合成トラックごとの単色。読み込みを挟まないので速く、結果が決まっている。テスト向け。
        case stub
        /// 素材ファイルから本当にデコードする。`player` と見比べるとき向け。
        case decoded
    }

    let project: Project
    let built: BuiltComposition
    private let instructions: [NanovidInstruction]

    // Metal の CIContext を作るのが重いので、使い回す。
    private static let compositor = NanovidCompositor()

    private var generators: [URL: AVAssetImageGenerator] = [:]
    /// 単色の代用フレーム。毎回塗ると、大きなキャンバスでは合成そのものより重くなる。
    private var stubs: [CMPersistentTrackID: CVPixelBuffer] = [:]

    init(project: Project, built: BuiltComposition) {
        self.project = project
        self.built = built
        self.instructions = built.videoComposition.instructions.compactMap { $0 as? NanovidInstruction }
    }

    /// 組み立てまで済ませる。描くのは何枚でもよい。
    /// - Parameter constantFrameRate: 書き出しと同じ命令にする（既定）。プレビューと同じに
    ///   したいときは false。
    static func make(project: Project, baseURL: URL?,
                     constantFrameRate: Bool = true) async throws -> FrameRenderer {
        let built = try await CompositionBuilder.build(project: project, baseURL: baseURL,
                                                       constantFrameRate: constantFrameRate)
        return FrameRenderer(project: project, built: built)
    }

    var canvasSize: CGSize { project.canvas.size }

    /// その時刻の命令。命令列の外なら nil。
    func instruction(at time: Double) -> NanovidInstruction? {
        let target = time.cmTime
        return instructions.first { $0.timeRange.start <= target && target < $0.timeRange.end }
    }

    /// 見えるレイヤーの組み合わせが変わらない区間ごとの、真ん中の時刻。
    /// どこを描けばよいか決まっていないとき、全部の組み合わせを 1 枚ずつ見るのに使う。
    func segmentMidpoints() -> [Double] {
        instructions.map {
            ($0.timeRange.start.secondsOrZero + $0.timeRange.end.secondsOrZero) / 2
        }
    }

    // MARK: - 描く

    func render(at time: Double, path: Path, sources: Sources = .stub) async throws -> CGImage {
        switch path {
        case .direct: return try renderDirect(at: time, sources: sources)
        case .player: return try await renderPlayer(at: time)
        }
    }

    /// 自前の合成を直に呼ぶ。
    func renderDirect(at time: Double, sources: Sources = .stub) throws -> CGImage {
        guard let instruction = instruction(at: time) else { throw RenderError.outsideComposition(time) }
        let canvas = canvasSize
        var cache: [CMPersistentTrackID: CVPixelBuffer] = [:]
        let image = Self.compositor.render(instruction: instruction, at: time) { trackID in
            if let hit = cache[trackID] { return hit }
            let buffer: CVPixelBuffer?
            switch sources {
            case .stub:
                buffer = self.stubs[trackID] ?? Self.stubBuffer(for: trackID, size: canvas)
                self.stubs[trackID] = buffer
            case .decoded: buffer = self.decodedBuffer(trackID: trackID, at: time)
            }
            cache[trackID] = buffer
            return buffer
        }
        guard let image else { throw RenderError.compositorFailed(time) }
        return image
    }

    /// AVFoundation に描かせる。プレビュー・書き出しと同じ経路。
    /// - Parameter maxWidth: 縮小したいとき。nil ならキャンバスの大きさのまま。
    func renderPlayer(at time: Double, maxWidth: Double? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        if let maxWidth {
            let edge = max(64, min(4096, maxWidth))
            generator.maximumSize = CGSize(width: edge, height: edge)
        }
        let (image, _) = try await generator.image(at: max(0, time).cmTime)
        return image
    }

    // MARK: - 中身の説明

    /// その時刻に何をどう重ねるか。描いた絵と並べて読むためのもの。
    struct Description: Codable {
        struct Layer: Codable {
            /// media / still / text
            var kind: String
            var trackID: Int32?
            /// 元の画像の大きさ（文字と静止画）。
            var imageSize: [Int]?
            /// キャンバス座標（左上原点）での配置。文字だけ。
            var rect: [Double]?
            var alpha: Double
            var clipStart: Double
            var clipDuration: Double
        }
        var time: Double
        /// 命令の区間 [start, end)。
        var segment: [Double]
        var layers: [Layer]
    }

    func describe(at time: Double) -> Description? {
        guard let instruction = instruction(at: time) else { return nil }
        let layers = instruction.layers.map { layer -> Description.Layer in
            var d = Description.Layer(kind: "", alpha: layer.alpha(at: time),
                                      clipStart: layer.clipStart, clipDuration: layer.clipDuration)
            switch layer.source {
            case .media(let id, _):
                d.kind = "media"
                d.trackID = id
            case .still(let image):
                d.kind = "still"
                d.imageSize = [image.width, image.height]
            case .text(let image, let rect):
                d.kind = "text"
                d.imageSize = [image.width, image.height]
                let values: [Double] = [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
                d.rect = values.map { ($0 * 10).rounded() / 10 }
            }
            return d
        }
        return Description(time: time,
                           segment: [instruction.timeRange.start.secondsOrZero,
                                     instruction.timeRange.end.secondsOrZero],
                           layers: layers)
    }

    // MARK: - 素材フレーム

    /// 単色の代用フレームの色。合成トラックの ID ごとに変えて、どのクリップが
    /// 映っているか絵から見分けられるようにする。
    static func stubColor(for trackID: CMPersistentTrackID) -> (r: UInt8, g: UInt8, b: UInt8) {
        let table: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (255, 255, 0), (255, 0, 255), (0, 255, 255),
        ]
        return table[Int(trackID) % table.count]
    }

    static func stubBuffer(for trackID: CMPersistentTrackID, size: CGSize) -> CVPixelBuffer? {
        guard let buffer = makeBuffer(width: Int(size.width), height: Int(size.height)) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let color = stubColor(for: trackID)
        let raw = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let i = y * bytesPerRow + x * 4
                raw[i] = color.b                 // BGRA の並び
                raw[i + 1] = color.g
                raw[i + 2] = color.r
                raw[i + 3] = 255
            }
        }
        return buffer
    }

    /// 合成トラックのその時刻に入っている素材を、元のファイルからデコードする。
    ///
    /// 合成トラックの区間が「どのファイルのどこを、どこへ置いたか」を持っているので、
    /// そこから元ファイルの時刻を逆算する。
    private func decodedBuffer(trackID: CMPersistentTrackID, at time: Double) -> CVPixelBuffer? {
        guard let track = built.composition.track(withTrackID: trackID) else { return nil }
        let target = time.cmTime
        guard let segment = track.segments.first(where: {
            !$0.isEmpty && $0.timeMapping.target.containsTime(target)
        }), let url = segment.sourceURL else { return nil }

        let mapping = segment.timeMapping
        let offset = (target - mapping.target.start).secondsOrZero
        let rate = mapping.target.duration.secondsOrZero > 0
            ? mapping.source.duration.secondsOrZero / mapping.target.duration.secondsOrZero : 1
        let sourceTime = mapping.source.start.secondsOrZero + offset * rate

        let generator = generators[url] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            // 向きの補正はコンポジタが preferredTransform で掛ける。ここで掛けると二重になる。
            g.appliesPreferredTrackTransform = false
            generators[url] = g
            return g
        }()
        guard let image = try? generator.copyCGImage(at: sourceTime.cmTime, actualTime: nil) else {
            return nil
        }
        return Self.buffer(from: image)
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard width > 0, height > 0,
              CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    private static func buffer(from image: CGImage) -> CVPixelBuffer? {
        guard let buffer = makeBuffer(width: image.width, height: image.height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    enum RenderError: LocalizedError {
        case outsideComposition(Double)
        case compositorFailed(Double)

        var errorDescription: String? {
            switch self {
            case .outsideComposition(let t):
                return String(format: "%.3f 秒は合成の範囲の外です。", t)
            case .compositorFailed(let t):
                return String(format: "%.3f 秒を合成できませんでした。", t)
            }
        }
    }
}

// MARK: - 画素

/// 描いた絵を RGBA の画素列にしたもの。比べたり、1 点の色を読んだりする。
struct RGBAFrame {
    let width: Int
    let height: Int
    /// RGBA を 1 バイトずつ並べたもの。
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// キャンバス上の比の位置（0…1、左上が原点）で 1 画素を読む。
    func color(atX x: Double, y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        let i = (py * width + px) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    /// 全画素の成分ごとの差の平均（0…255）。0 なら同じ絵。大きさが違えば 255。
    func difference(from other: RGBAFrame) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var total = 0
        for i in 0..<pixels.count {
            total += abs(Int(pixels[i]) - Int(other.pixels[i]))
        }
        return Double(total) / Double(max(1, pixels.count))
    }

    /// 差が `threshold` を超える画素の割合（0…1）。
    /// 平均だけだと「小さな文字が 1 つ消えた」が埋もれるので、こちらも見る。
    func changedFraction(from other: RGBAFrame, threshold: Int = 16) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var changed = 0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(pixels[p + c]) - Int(other.pixels[p + c]))) }
            if d > threshold { changed += 1 }
        }
        return Double(changed) / Double(max(1, width * height))
    }

    /// 差のある画素を赤く、同じ画素を薄い灰色にした絵。どこが違うかを見るため。
    func differenceImage(from other: RGBAFrame, threshold: Int = 16) -> CGImage? {
        guard width == other.width, height == other.height else { return nil }
        var out = [UInt8](repeating: 0, count: pixels.count)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(pixels[p + c]) - Int(other.pixels[p + c]))) }
            if d > threshold {
                out[p] = 255; out[p + 1] = 0; out[p + 2] = 0
            } else {
                let gray = UInt8((Int(pixels[p]) + Int(pixels[p + 1]) + Int(pixels[p + 2])) / 12)
                out[p] = gray; out[p + 1] = gray; out[p + 2] = gray
            }
            out[p + 3] = 255
        }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

extension CGImage {
    /// PNG にして書く。
    func writePNG(to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
