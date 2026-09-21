import AVFoundation
import Foundation
import Observation

/// マイク録音。録った WAV はそのまま素材になる（変換もテンポラリも挟まない）。
@Observable
final class AudioRecorder {

    enum State: Equatable {
        case idle
        case denied
        case recording(since: Date)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// 直近のピークレベル (0...1)。波形メーター表示用。
    private(set) var level: Double = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var outputURL: URL?

    var isRecording: Bool { if case .recording = state { return true }; return false }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            state = .denied
            return false
        }
    }

    /// 録音を開始する。出力先は呼び出し側が決める（既定ではプロジェクトの隣）。
    @discardableResult
    func start(to url: URL) async -> Bool {
        guard !isRecording else { return false }
        guard await requestPermission() else { return false }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: min(2, format.channelCount),
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            self.file = audioFile
            self.outputURL = url

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.file?.write(from: buffer)
                self.updateLevel(buffer)
            }
            engine.prepare()
            try engine.start()
            state = .recording(since: Date())
            return true
        } catch {
            state = .failed(error.localizedDescription)
            cleanup()
            return false
        }
    }

    /// 録音を終え、書き出した WAV の URL を返す。
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        let url = outputURL
        cleanup()
        state = .idle
        level = 0
        return url
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        outputURL = nil
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        for i in stride(from: 0, to: n, by: 8) { peak = max(peak, abs(data[i])) }
        let value = Double(peak)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 表示のちらつきを抑えるため、下がるときだけなだらかにする。
            self.level = value > self.level ? value : self.level * 0.8 + value * 0.2
        }
    }
}
