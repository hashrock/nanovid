import AVFoundation
import Foundation

struct ExportSettings: Hashable {
    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: String { rawValue }
        var label: String { self == .h264 ? L("H.264 (互換性重視)") : L("HEVC (高圧縮)") }
        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case standard, high, max
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return L("標準")
            case .high: return L("高")
            case .max: return L("最高")
            }
        }
        /// 画素あたりのビット数の目安。
        var bitsPerPixel: Double {
            switch self {
            case .standard: return 0.10
            case .high: return 0.16
            case .max: return 0.24
            }
        }
    }

    var codec: Codec = .h264
    var quality: Quality = .high
    var audioBitrate: Int = 192_000

    func videoBitrate(canvas: CanvasSpec) -> Int {
        let raw = Double(canvas.width * canvas.height * canvas.fps) * quality.bitsPerPixel
        // HEVC は同画質で概ね 3 割ほど低いビットレートで足りる。
        let adjusted = codec == .hevc ? raw * 0.7 : raw
        return Int(max(1_000_000, min(adjusted, 120_000_000)))
    }
}

enum ExportError: LocalizedError {
    case cancelled
    case reader(String)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return L("書き出しを中止しました。")
        case .reader(let m): return L("読み込みに失敗しました: \(m)")
        case .writer(let m): return L("書き出しに失敗しました: \(m)")
        }
    }
}

/// AVAssetReader → AVAssetWriter で書き出す。
/// プレビューと同じ NanovidCompositor を通すので、見た目は完全に一致する。
final class Exporter {

    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private let cancelLock = NSLock()
    private var isCancelled = false

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return isCancelled
    }

    func export(project: Project,
                baseURL: URL?,
                to outputURL: URL,
                settings: ExportSettings,
                progress: @escaping @Sendable (Double) -> Void) async throws {

        // 範囲の外のクリップを落としてから組む。範囲外は背景だけになるので、
        // 合成の手間はほとんどかからない。
        let built = try await CompositionBuilder.build(project: project.croppedToOutputRange(),
                                                       baseURL: baseURL,
                                                       constantFrameRate: true)
        let canvas = project.canvas
        // 書き出すのはこの範囲だけ。合成は 0 秒から始めたままにして、
        // 頭出しは AVAssetWriter のセッション開始時刻でそろえる。
        let outputStart = min(project.outputStart, built.duration)
        let outputEnd = max(min(project.outputEnd, built.duration),
                            outputStart + canvas.frameDuration)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // MARK: Reader
        let reader = try AVAssetReader(asset: built.composition)
        self.reader = reader

        let videoTracks = built.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.reader(L("映像出力を追加できません")) }
        reader.add(videoOutput)

        let audioTracks = built.composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
            ])
            out.audioMix = built.audioMix
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // MARK: Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        self.writer = writer
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate(canvas: canvas),
            AVVideoExpectedSourceFrameRateKey: canvas.fps,
            AVVideoMaxKeyFrameIntervalKey: canvas.fps * 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writer(L("映像入力を追加できません")) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? L("不明なエラー"))
        }
        guard reader.startReading() else {
            throw ExportError.reader(reader.error?.localizedDescription ?? L("不明なエラー"))
        }
        // 範囲の先頭を出力の 0 秒に対応させる。AVAssetWriter がこの差を引いてくれる。
        writer.startSession(atSourceTime: outputStart.cmTime)

        let total = max(outputEnd - outputStart, 0.001)
        async let videoDone: Void = pump(input: videoInput, output: videoOutput, label: "video",
                                         skipBefore: outputStart, stopAfter: outputEnd) { pts in
            progress(min(1, max(0, pts - outputStart) / total))
        }
        async let audioDone: Void = {
            guard let audioInput, let audioOutput else { return }
            try await pump(input: audioInput, output: audioOutput, label: "audio",
                           skipBefore: outputStart, stopAfter: outputEnd, onProgress: nil)
        }()

        _ = try await (videoDone, audioDone)

        // 範囲の終わりで閉じる。端にかかるクリップは切らずに残してあるので、
        // 合成そのものは範囲より先まで続いていることがある。
        writer.endSession(atSourceTime: outputEnd.cmTime)

        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.reader(reader.error?.localizedDescription ?? L("不明なエラー"))
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.writer(writer.error?.localizedDescription ?? L("不明なエラー"))
        }
        progress(1)
    }

    /// 1 系統ぶんのサンプルを読んで書く。
    /// - Parameters:
    ///   - skipBefore: この時刻より前のサンプルは捨てる。
    ///     セッション開始より手前を渡さないことで、出力の頭をそろえる。
    ///   - stopAfter: この時刻を過ぎたら読むのをやめる。
    private func pump(input: AVAssetWriterInput,
                      output: AVAssetReaderOutput,
                      label: String,
                      skipBefore: Double,
                      stopAfter: Double,
                      onProgress: (@Sendable (Double) -> Void)?) async throws {
        let queue = DispatchQueue(label: "nanovid.export.\(label)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { cont.resume(); return }
                while input.isReadyForMoreMediaData {
                    if self.cancelled {
                        input.markAsFinished()
                        cont.resume(throwing: ExportError.cancelled)
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).secondsOrZero
                    if pts < skipBefore - 1e-9 { continue }
                    if pts > stopAfter - 1e-9 {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        cont.resume(throwing: ExportError.writer(label))
                        return
                    }
                    onProgress?(pts)
                }
            }
        }
    }
}
