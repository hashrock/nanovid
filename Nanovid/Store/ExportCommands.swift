import AppKit
import Foundation
import UniformTypeIdentifiers

/// 動画のほかに外へ出すもの: 音声だけ、字幕。
///
/// どちらも行き先は毎回標準の保存パネルで選んでもらう（決め打ちの場所には
/// 書かない。パネルで選んだ場所は App Sandbox の下でも書ける）。
/// 入口は「ファイル」メニュー。動画の書き出し（ツールバー → シート）と違って
/// 決めることが形式しか無いので、メニューで形式を選んだらすぐ保存パネルを出す。
extension EditorStore {

    // MARK: - 音声だけ

    /// 音声を書き出せるか（中身があり、ほかの書き出しが動いていない）。
    var canExportAudio: Bool { audioExportProgress == nil && duration > 0 }

    /// 保存パネルで場所を選んでもらい、タイムラインの音だけを書き出す。
    @MainActor
    func exportAudioWithPanel(format: AudioExportFormat) {
        guard canExportAudio else { return }
        guard let url = chooseExportDestination(fileExtension: format.fileExtension) else { return }
        Task { @MainActor in
            do {
                try await exportAudio(to: url, format: format)
            } catch {
                presentError(L("書き出せませんでした"), error.localizedDescription)
            }
        }
    }

    /// タイムラインの音だけを書き出す（パネルなし）。進み具合は audioExportProgress。
    @MainActor
    func exportAudio(to url: URL, format: AudioExportFormat) async throws {
        guard audioExportProgress == nil else { throw ExportError.writer(L("ほかの書き出しが動いています")) }
        pause()
        audioExportProgress = 0
        defer { audioExportProgress = nil }
        try await AudioExporter().export(project: project, baseURL: baseURL, to: url, format: format) { value in
            Task { @MainActor [weak self] in
                // 終わったあとに届いたぶんで、表示を出し直さない。
                if self?.audioExportProgress != nil { self?.audioExportProgress = value }
            }
        }
    }

    // MARK: - 字幕

    /// 書き出せる字幕があるか。
    var canExportSubtitles: Bool { !SubtitleExport.cues(from: project).isEmpty }

    /// 保存パネルで場所を選んでもらい、字幕ファイルを書き出す。
    func exportSubtitlesWithPanel(format: SubtitleExport.Format) {
        guard canExportSubtitles else { return }
        guard let url = chooseExportDestination(fileExtension: format.fileExtension) else { return }
        do {
            try exportSubtitles(to: url, format: format)
        } catch {
            presentError(L("書き出せませんでした"), error.localizedDescription)
        }
    }

    /// 字幕ファイルを書き出す（パネルなし）。
    /// - Returns: 書いた字幕の枚数。
    @discardableResult
    func exportSubtitles(to url: URL, format: SubtitleExport.Format) throws -> Int {
        let cues = SubtitleExport.cues(from: project)
        try Data(SubtitleExport.string(cues, format: format).utf8).write(to: url, options: .atomic)
        return cues.count
    }

    // MARK: - 行き先

    /// 書き出し先を標準の保存パネルで選んでもらう。キャンセルなら nil。
    func chooseExportDestination(fileExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let name = project.name.isEmpty ? "movie" : project.name
        panel.nameFieldStringValue = "\(name).\(fileExtension)"
        // 開いたときの場所の提案だけ。どこに置くかはユーザーが決める。
        if let dir = baseURL { panel.directoryURL = dir }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
