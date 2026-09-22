import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@testable import Nanovid

/// プロジェクトを組んで、実際に 1 フレーム描くところまでを通す道具。
///
/// 再生も書き出しも通さない。`CompositionBuilder` が出した命令を
/// `NanovidCompositor` にそのまま渡すので、画面に出るものと同じ絵が得られる。
/// 素材のフレームは合成トラックごとの単色で代用する（読み込みを挟まない）。
@MainActor
enum HeadlessRender {

    struct Frame {
        let width: Int
        let height: Int
        /// RGBA を 1 バイトずつ並べたもの。
        let pixels: [UInt8]

        /// キャンバス上の比の位置（0…1、左上が原点）で 1 画素を読む。
        func color(atX x: Double, y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
            let px = min(width - 1, max(0, Int(x * Double(width))))
            let py = min(height - 1, max(0, Int(y * Double(height))))
            let i = (py * width + px) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
        }

        /// 全画素の成分ごとの差の平均。0 なら同じ絵。
        func difference(from other: Frame) -> Double {
            guard width == other.width, height == other.height else { return 255 }
            var total = 0
            for i in 0..<min(pixels.count, other.pixels.count) {
                total += abs(Int(pixels[i]) - Int(other.pixels[i]))
            }
            return Double(total) / Double(pixels.count)
        }
    }

    /// 素材の代わりに敷く単色。合成トラックの ID ごとに色を変えて、
    /// どのクリップが映っているか画から見分けられるようにする。
    static func stubColor(for trackID: CMPersistentTrackID) -> (r: UInt8, g: UInt8, b: UInt8) {
        let table: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (255, 255, 0), (255, 0, 255), (0, 255, 255),
        ]
        return table[Int(trackID) % table.count]
    }

    /// 組み立てを 1 回で済ませて、好きな時刻を何枚でも描ける入れ物。
    /// フレームごとに組み直すと、合成の組み立てが支配的になって遅い。
    @MainActor
    struct Renderer {
        private let instructions: [NanovidInstruction]
        private let canvas: CGSize
        // Metal の CIContext を作るのが重いので、使い回す。
        private static let compositor = NanovidCompositor()
        private var compositor: NanovidCompositor { Self.compositor }

        init(project: Project, built: BuiltComposition) {
            instructions = built.videoComposition.instructions.compactMap { $0 as? NanovidInstruction }
            canvas = project.canvas.size
        }

        /// 指定時刻の絵を描く。命令が見つからなければ nil。
        func frame(at time: Double) -> Frame? {
            let target = time.cmTime
            guard let instruction = instructions.first(where: {
                $0.timeRange.start <= target && target < $0.timeRange.end
            }) else { return nil }
            guard let image = compositor.render(instruction: instruction, at: time,
                                                sourceFrame: { stub(for: $0, size: canvas) })
            else { return nil }
            return read(image)
        }
    }

    static func renderer(for project: Project, constantFrameRate: Bool = true) async throws -> Renderer {
        let built = try await CompositionBuilder.build(project: project, baseURL: nil,
                                                       constantFrameRate: constantFrameRate)
        return Renderer(project: project, built: built)
    }

    /// 1 枚だけ欲しいとき。
    static func frame(of project: Project, at time: Double,
                      constantFrameRate: Bool = true) async throws -> Frame? {
        try await renderer(for: project, constantFrameRate: constantFrameRate).frame(at: time)
    }

    // MARK: 中身

    /// 素材フレームの代わりの単色バッファ。
    private static func stub(for trackID: CMPersistentTrackID, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

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

    private static func read(_ image: CGImage) -> Frame? {
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
        return ok ? Frame(width: width, height: height, pixels: pixels) : nil
    }
}
