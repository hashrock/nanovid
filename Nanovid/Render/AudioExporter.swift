import AVFoundation
import Foundation

/// 音声だけの書き出しの形式。
enum AudioExportFormat: String, CaseIterable {
    /// AAC（192 kbps）。動画の書き出しに入る音声と同じ。
    case m4a
    /// 圧縮しない PCM（16 bit）。ほかの編集ソフトへ渡すとき用。
    case wav

    var fileExtension: String { rawValue }
    var fileType: AVFileType { self == .m4a ? .m4a : .wav }

    static let sampleRate = 48_000.0
    static let channels = 2

    var writerSettings: [String: Any] {
        switch self {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: Self.channels,
                    AVEncoderBitRateKey: ExportSettings().audioBitrate]
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: Self.channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
        }
    }
}

/// タイムラインの音だけを、聞こえるとおりに（ミュート・音量・フェード込みで）
/// 音声ファイルへ書き出す。ナレーションだけ別のアプリへ渡したいとき用。
///
/// 音は動画の書き出しと同じ合成（TimelineAudio）から引く。書き出す範囲にも従う。
/// 範囲の頭がファイルの 0 秒になる。
final class AudioExporter {

    private let cancelLock = NSLock()
    private var isCancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
        reader?.cancelReading()
    }

    private var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return isCancelled
    }

    /// 読み出しと同じ形（Float32・インターリーブ・48kHz・ステレオ）の無音。
    /// - Parameters:
    ///   - start: 書き出す範囲の頭（秒）。
    ///   - offsetFrames: 範囲の頭から数えた、この無音の置き場所。
    private static func silence(frames: Int, at start: Double, offsetFrames: Int) -> CMSampleBuffer? {
        let channels = AudioExportFormat.channels
        let bytesPerFrame = MemoryLayout<Float32>.size * channels
        var description = AudioStreamBasicDescription(
            mSampleRate: AudioExportFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        let length = frames * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: length) == noErr else { return nil }

        let rate = CMTimeScale(AudioExportFormat.sampleRate)
        let time = CMTimeAdd(start.cmTime, CMTime(value: CMTimeValue(offsetFrames), timescale: rate))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    func export(project: Project,
                baseURL: URL?,
                to outputURL: URL,
                format: AudioExportFormat,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let outputStart = project.outputStart
        let outputEnd = project.outputEnd
        guard outputEnd - outputStart > 1e-9 else { throw TimelineAudioError.noAudio }

        // 映像と違って、音声は reader の timeRange で範囲を切れる（サンプル単位で揃う）。
        let range = CMTimeRange(start: outputStart.cmTime, end: outputEnd.cmTime)
        let (reader, output, _) = try await TimelineAudio.startReading(
            project: project.croppedToOutputRange(), baseURL: baseURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioExportFormat.sampleRate,
                AVNumberOfChannelsKey: AudioExportFormat.channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            timeRange: range)
        self.reader = reader

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: format.fileType)
        self.writer = writer
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.writer(L("音声入力を追加できません")) }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? L("不明なエラー"))
        }
        // 範囲の頭を出力の 0 秒に対応させる。
        writer.startSession(atSourceTime: range.start)

        let total = max(outputEnd - outputStart, 0.001)
        // 合成の音は、最後の音声クリップが終わったところで尽きる。そのままだと、
        // テロップだけが続く動画では音声ファイルのほうが短くなる。範囲の終わりまで
        // 無音を足して、長さを動画とそろえる。
        let wantedFrames = Int((total * AudioExportFormat.sampleRate).rounded())
        var writtenFrames = 0
        var sourceDone = false
        let queue = DispatchQueue(label: "nanovid.export.audio-only")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { cont.resume(); return }
                while input.isReadyForMoreMediaData {
                    if self.cancelled {
                        input.markAsFinished()
                        cont.resume(throwing: ExportError.cancelled)
                        return
                    }
                    let sample: CMSampleBuffer
                    if !sourceDone, let next = output.copyNextSampleBuffer() {
                        sample = next
                    } else {
                        sourceDone = true
                        let missing = wantedFrames - writtenFrames
                        // 読み込みが失敗して尽きたときは、無音でごまかさない。
                        guard missing > 0, reader.status != .failed,
                              let silence = Self.silence(frames: min(missing, 8192),
                                                         at: outputStart, offsetFrames: writtenFrames) else {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                        sample = silence
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        cont.resume(throwing: ExportError.writer(
                            writer.error?.localizedDescription ?? L("不明なエラー")))
                        return
                    }
                    writtenFrames += CMSampleBufferGetNumSamples(sample)
                    progress(min(1, Double(writtenFrames) / Double(max(1, wantedFrames))))
                }
            }
        }

        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.reader(reader.error?.localizedDescription ?? L("不明なエラー"))
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.writer(writer.error?.localizedDescription ?? L("不明なエラー"))
        }
        progress(1)
    }
}
