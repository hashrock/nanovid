import AVFoundation
import Foundation

/// タイムラインの音を、短い窓ごとの大きさに直す（無音カット用）。
enum AudioLevelMeter {

    /// 大きさを見るだけなので、声の帯域が入れば足りる。
    static let sampleRate = 16_000.0
    static let window = 0.01

    /// 書き出す範囲だけを測る。範囲の外は抜かないので読むだけ無駄になる。
    static func measure(project: Project, baseURL: URL?) async throws -> AudioLevels {
        let range = CMTimeRange(start: project.outputStart.cmTime, end: project.outputEnd.cmTime)
        let (reader, output, _) = try await TimelineAudio.startReading(
            project: project, baseURL: baseURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            timeRange: range)

        let perWindow = Int(sampleRate * window)
        var rms: [Float] = []
        rms.reserveCapacity(Int(project.duration / window) + 1)
        var origin: Double?
        var sum: Float = 0
        var filled = 0
        // 写し取り先は使い回す。足りなくなったときだけ広げる。
        var samples: [Float] = []

        while let sample = output.copyNextSampleBuffer() {
            if origin == nil { origin = CMSampleBufferGetPresentationTimeStamp(sample).secondsOrZero }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            // ブロックは連続しているとは限らないので、ポインタを覗かずに写し取る。
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                           dataLength: count * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            for value in samples[..<count] {
                sum += value * value
                filled += 1
                if filled == perWindow {
                    rms.append((sum / Float(filled)).squareRoot())
                    sum = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { rms.append((sum / Float(filled)).squareRoot()) }

        if reader.status == .failed {
            throw TimelineAudioError.readFailed(reader.error?.localizedDescription ?? L("不明なエラー"))
        }
        return AudioLevels(origin: origin ?? project.outputStart, window: window, rms: rms)
    }
}
