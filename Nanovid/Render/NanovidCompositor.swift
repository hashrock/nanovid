import AVFoundation
import CoreImage
import CoreMedia
import Metal

/// Core Image で全レイヤーを 1 枚に合成するカスタムコンポジタ。
/// プレビューも書き出しもこのクラスを通るので、見た目が必ず一致する。
final class NanovidCompositor: NSObject, AVVideoCompositing {

    private let renderQueue = DispatchQueue(label: "nanovid.compositor.render")
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                .cacheIntermediates: false,
            ])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var supportsWideColorSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { self.renderContext = newRenderContext }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            guard let instruction = request.videoCompositionInstruction as? NanovidInstruction else {
                request.finish(with: CompositorError.badInstruction)
                return
            }
            guard let destination = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noBuffer)
                return
            }
            let time = request.compositionTime.secondsOrZero
            let image = self.compose(instruction: instruction, request: request, at: time)
            self.ciContext.render(image, to: destination,
                                  bounds: CGRect(origin: .zero, size: instruction.canvasSize),
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            request.finish(withComposedVideoFrame: destination)
        }
    }

    // MARK: - 合成

    private func compose(instruction: NanovidInstruction,
                         request: AVAsynchronousVideoCompositionRequest,
                         at time: Double) -> CIImage {
        let canvas = instruction.canvasSize
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let bg = instruction.backgroundColor
        var result = CIImage(color: CIColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a))
            .cropped(to: canvasRect)

        for layer in instruction.layers {
            let alpha = layer.alpha(at: time)
            guard alpha > 0.001 else { continue }
            guard var image = sourceImage(for: layer, request: request, canvas: canvas) else { continue }
            if alpha < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
            }
            result = image.composited(over: result)
        }
        return result.cropped(to: canvasRect)
    }

    private func sourceImage(for layer: RenderLayer,
                             request: AVAsynchronousVideoCompositionRequest,
                             canvas: CGSize) -> CIImage? {
        switch layer.source {
        case .media(let trackID, let preferred):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            var image = CIImage(cvPixelBuffer: buffer)
            if !preferred.isIdentity {
                image = image.transformed(by: preferred)
                // 回転で原点がずれるので左下に寄せ直す。
                let e = image.extent
                image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            }
            return image.transformed(by: fitTransform(for: image.extent.size, in: canvas, layer: layer))

        case .text(let cgImage, let rect):
            // 配置の計算は OverlayLayout と共有する。プレビューのハンドルが
            // 実際に映るものとずれないようにするため。
            return CIImage(cgImage: cgImage).transformed(
                by: OverlayLayout.ciTransform(content: rect,
                                              transform: layer.transform,
                                              canvas: canvas))
        }
    }

    /// 映像を「キャンバスに収める」基準配置にしたうえで、クリップの変形を適用する。
    /// 位置と大きさの計算は MediaLayout と共有する。プレビューのハンドルが
    /// 実際に映るものとずれないようにするため。
    private func fitTransform(for size: CGSize, in canvas: CGSize, layer: RenderLayer) -> CGAffineTransform {
        guard size.width > 0, size.height > 0 else { return .identity }
        let rect = MediaLayout.rect(naturalSize: size, transform: layer.transform, canvas: canvas)
        let scale = rect.width / size.width

        // Core Image は左下原点なので y を反転して渡す。
        return CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: canvas.height - rect.midY)
            .rotated(by: layer.transform.rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    enum CompositorError: Error {
        case badInstruction
        case noBuffer
    }
}
