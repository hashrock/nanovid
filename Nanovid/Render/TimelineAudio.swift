import AVFoundation
import Foundation

enum TimelineAudioError: LocalizedError {
    case noAudio
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return L("タイムラインに音声がありません。")
        case .readFailed(let message):
            return L("音声を読み込めませんでした: \(message)")
        }
    }
}

/// タイムラインの音を、聞こえるとおりに（ミュート・音量・フェード込みで）PCM として引く。
///
/// 合成済みの音声ミックスから直接読むので、音声ファイルを書き出さずに済む
/// （このアプリの「中間ファイルを作らない」方針のまま）。書き起こしと無音カットが使う。
enum TimelineAudio {

    /// 読み始めた reader と、サンプルを引く出力を返す。
    /// - Parameter timeRange: 読む範囲。nil なら全体。
    static func startReading(project: Project, baseURL: URL?,
                             settings: [String: Any],
                             timeRange: CMTimeRange? = nil) async throws
        -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, duration: Double) {
        let built = try await CompositionBuilder.build(project: project, baseURL: baseURL)
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TimelineAudioError.noAudio }

        let reader = try AVAssetReader(asset: built.composition)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        output.audioMix = built.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TimelineAudioError.readFailed(L("音声出力を追加できません"))
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TimelineAudioError.readFailed(reader.error?.localizedDescription ?? L("不明なエラー"))
        }
        return (reader, output, built.duration)
    }
}
