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

    /// 音声ファイル（や動画の音声トラック）を、48kHz・モノラルのサンプル列（-1...1）で読む。
    /// 音声トラックが無ければ nil。
    static func samples(of url: URL) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var all: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count,
                                               destination: raw.baseAddress!)
                for value in raw.bindMemory(to: Int16.self) {
                    all.append(Float(value) / Float(Int16.max))
                }
            }
        }
        return all
    }

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
