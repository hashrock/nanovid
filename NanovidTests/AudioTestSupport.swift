import AVFoundation
import Foundation
@testable import Nanovid

/// 音声を作って・読んで確かめるための道具。
enum TestAudio {

    /// 440Hz の正弦波を WAV で書く。録音や取り込んだ音声の代わり。
    static func writeTone(to url: URL, seconds: Double, amplitude: Float = 0.5) throws {
        let sampleRate = 48000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate)) * amplitude
        }
        try file.write(from: buffer)
    }

    /// 音声ファイル（や動画の音声トラック）を、モノラルのサンプル列（-1...1）で読む。
    /// 音声トラックが無ければ nil。サンプルレートはファイルのまま（このテストで扱う
    /// ものはどれも 48kHz）。
    ///
    /// CI（GitHub の macOS ランナー）で、ここが終わらずにテスト全体が止まったことがある。
    /// 止まっていたのは copyNextSampleBuffer の中で、直前に音声変換器のエラー
    /// （FAC -12783）が出ていた。そのときは読み出しにモノラル化とサンプルレートの
    /// 指定を付けていた。手元では再現しない。そこで:
    /// - 読み出しには変換を頼まない（16bit の PCM にするだけ）。モノラルへは自分で均す。
    /// - 読み出しは終わるまで戻らない同期の呼び出しなので、Swift の並行処理用の
    ///   スレッドを塞がないよう専用のキューで回す。万一また止まっても、ほかの
    ///   テストまで巻き込まない。
    static func samples(of url: URL) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                guard reader.startReading() else {
                    continuation.resume(throwing: reader.error ?? CocoaError(.fileReadUnknown))
                    return
                }
                var all: [Float] = []
                while let sample = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let channels = CMSampleBufferGetFormatDescription(sample)
                        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                        .map { max(1, Int($0.pointee.mChannelsPerFrame)) } ?? 1
                    var data = Data(count: CMBlockBufferGetDataLength(block))
                    data.withUnsafeMutableBytes { raw in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count,
                                                       destination: raw.baseAddress!)
                        let values = raw.bindMemory(to: Int16.self)
                        // チャンネルを均して 1 本にする。
                        for frame in stride(from: 0, to: values.count - channels + 1, by: channels) {
                            var sum: Float = 0
                            for c in 0..<channels { sum += Float(values[frame + c]) }
                            all.append(sum / Float(channels) / Float(Int16.max))
                        }
                    }
                }
                if reader.status == .failed {
                    continuation.resume(throwing: reader.error ?? CocoaError(.fileReadUnknown))
                } else {
                    continuation.resume(returning: all)
                }
            }
        }
    }

    private static let readQueue = DispatchQueue(label: "nanovid.tests.audio-read", attributes: .concurrent)

    /// 秒で区切った範囲のピーク（0...1）。
    static func peak(_ samples: [Float], from: Double, to: Double) -> Float {
        let a = max(0, min(samples.count, Int(from * 48000)))
        let b = max(a, min(samples.count, Int(to * 48000)))
        return samples[a..<b].reduce(0) { max($0, abs($1)) }
    }

    /// 全体のピーク。音声トラックが無ければ nil。
    static func peak(of url: URL) async throws -> Float? {
        guard let all = try await samples(of: url) else { return nil }
        return peak(all, from: 0, to: Double(all.count) / 48000)
    }
}
