import AVFoundation
import Foundation
import Speech

/// 字幕の自動生成がこの環境で使えるか。
enum SubtitleGeneration {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var requirement: String { L("字幕の自動生成には macOS 26 以降が必要です。") }
}

/// 字幕の自動生成の進み具合。
///
/// 割合だけだと、言語モデルの取り寄せや音声の組み立てで長く 0% のまま止まって見える。
/// 実際に「聞き取り」に入るまでにいくつも段階があるので、どこにいるかを添える。
struct SubtitleProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// 言語モデルがあるか確かめている。
        case preparing
        /// 言語モデルを取り寄せている。初回だけ。
        case downloadingModel
        /// タイムラインの音声をまとめている。
        case buildingAudio
        /// 聞き取っている。
        case listening
        /// 聞き取りを終えて、結果をまとめている。
        case finishing

        var label: String {
            switch self {
            case .preparing: return L("準備中")
            case .downloadingModel: return L("言語モデルを取り寄せ中")
            case .buildingAudio: return L("音声をまとめ中")
            case .listening: return L("聞き取り中")
            case .finishing: return L("字幕にしています")
            }
        }
    }

    var phase: Phase
    /// 測れる段階だけ 0…1。測れないあいだは nil にして、ぐるぐるを出す。
    var fraction: Double?

    /// 画面に出す一文。
    var text: String {
        guard let fraction else { return phase.label }
        return "\(phase.label) \(Int((fraction * 100).rounded()))%"
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case noAudio
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return SubtitleGeneration.requirement
        case .unsupportedLocale(let name):
            return L("この言語には対応していません: \(name)")
        case .noAudio:
            return L("タイムラインに音声がありません。")
        case .readFailed(let message):
            return L("音声を読み込めませんでした: \(message)")
        }
    }
}

/// タイムラインの音声を端末内で書き起こす。
///
/// 合成済みの音声ミックスから直接 PCM を引いて流すので、書き起こしのために
/// 音声ファイルを書き出す必要がない（このアプリの「中間ファイルを作らない」方針のまま）。
///
/// SpeechAnalyzer は macOS 26 から。アプリ全体の対象 OS は上げず、
/// この機能だけを切り分けてある（`SubtitleGeneration.isAvailable` で判定）。
@available(macOS 26.0, *)
final class Transcriber {

    private var isCancelled = false
    private let lock = NSLock()

    func cancel() {
        lock.lock(); isCancelled = true; lock.unlock()
    }

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    /// 端末内で使える言語。
    static func availableLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func isSupported(_ locale: Locale) async -> Bool {
        let target = locale.identifier(.bcp47)
        return await SpeechTranscriber.supportedLocales
            .contains { $0.identifier(.bcp47) == target }
    }

    func transcribe(project: Project,
                    baseURL: URL?,
                    locale: Locale,
                    progress: @escaping @Sendable (SubtitleProgress) -> Void) async throws -> [TranscribedWord] {

        progress(SubtitleProgress(phase: .preparing, fraction: nil))
        guard await Self.isSupported(locale) else {
            throw TranscriptionError.unsupportedLocale(
                locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // 言語モデルが未導入なら取り寄せる。初回だけ時間がかかる。
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .unsupported:
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                // 初回は数百 MB 取り寄せることがある。何も出さないと固まって見える。
                progress(SubtitleProgress(phase: .downloadingModel, fraction: nil))
                let watching = Self.watch(request.progress) { fraction in
                    progress(SubtitleProgress(phase: .downloadingModel, fraction: fraction))
                }
                defer { watching.invalidate() }
                try await request.downloadAndInstall()
            }
        }

        progress(SubtitleProgress(phase: .buildingAudio, fraction: nil))
        let built = try await CompositionBuilder.build(project: project, baseURL: baseURL)
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriptionError.noAudio }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks,
                                                 audioSettings: Self.settings(for: format))
        output.audioMix = built.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriptionError.readFailed(L("音声出力を追加できません"))
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriptionError.readFailed(reader.error?.localizedDescription ?? L("不明なエラー"))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // 認識結果は解析と並行して届くので、先に受け皿を回しておく。
        let collecting = Task { () -> [TranscribedWord] in
            var words: [TranscribedWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(in: result.text))
            }
            return words
        }

        progress(SubtitleProgress(phase: .listening, fraction: 0))
        let total = max(built.duration, 0.001)
        let feeding = Task.detached { [format] in
            defer { continuation.finish() }
            while let sample = output.copyNextSampleBuffer() {
                if self.cancelled {
                    reader.cancelReading()
                    return
                }
                guard let buffer = Self.pcmBuffer(from: sample, format: format) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
                progress(SubtitleProgress(phase: .listening,
                                          fraction: min(1, time.secondsOrZero / total)))
            }
        }

        _ = try await analyzer.analyzeSequence(stream)
        await feeding.value
        // 音声を流し終えてからも、まだ認識結果が届く。ここで待つ。
        progress(SubtitleProgress(phase: .finishing, fraction: nil))
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        if cancelled { return [] }
        return try await collecting.value.sorted { $0.start < $1.start }
    }

    /// Progress を覗いて割合を流す。取り寄せの進み具合は KVO でしか取れない。
    private static func watch(_ progress: Progress,
                              report: @escaping @Sendable (Double) -> Void) -> NSKeyValueObservation {
        report(progress.fractionCompleted)
        return progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            report(progress.fractionCompleted)
        }
    }

    // MARK: - 変換まわり

    /// 認識結果の各区間を、時間付きの語として取り出す。
    private static func words(in text: AttributedString) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            words.append(TranscribedWord(text: piece,
                                         start: range.start.secondsOrZero,
                                         end: range.end.secondsOrZero))
        }
        return words
    }

    private static func settings(for format: AVAudioFormat) -> [String: Any] {
        let description = format.streamDescription.pointee
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: description.mSampleRate,
            AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: Int(description.mBitsPerChannel == 0 ? 32 : description.mBitsPerChannel),
            AVLinearPCMIsFloatKey: description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
        ]
    }

    private static func pcmBuffer(from sample: CMSampleBuffer,
                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
