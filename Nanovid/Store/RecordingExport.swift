import AppKit
import Foundation
import UniformTypeIdentifiers

/// 録音した音声を、書類の外へ取り出す。
///
/// 録音は書類（.nanovid パッケージ）の中の Recordings/ にあり、Finder からは
/// 見えない。ほかのアプリへ渡せるよう、選んでもらった場所へ WAV を写す。
/// 行き先は毎回標準のパネルで選んでもらう（決め打ちの場所には書かない。
/// パネルで選んだ場所は App Sandbox の下でも書ける）。
///
/// ファイルを写すだけの部分はここ（パネルも store も要らない）。パネルを出して
/// 呼ぶ側は下の EditorStore の拡張。
enum RecordingExport {

    /// このアプリで録音した音声か。
    ///
    /// 目印は持っていないので、置き場所と名前で見分ける。
    /// - 書類の中の Recordings/ にあるもの（いまの形式）
    /// - 名前が `rec-20261110-153000.wav` の形のもの。以前の版はプロジェクトの隣や
    ///   ユーザーが選んだフォルダに、この名前で置いていた
    static func isRecording(_ asset: MediaAsset, document: URL?) -> Bool {
        guard asset.kind == .audio else { return false }
        if let document, ProjectIO.isPackage(document) {
            let url = asset.url(relativeTo: document.deletingLastPathComponent())
            let folder = ProjectIO.recordingsDirectory(in: document).standardizedFileURL.path
            if url.path.hasPrefix(folder + "/") { return true }
        }
        let name = (asset.path as NSString).lastPathComponent
        return name.range(of: #"^rec-\d{8}-\d{6}\.wav$"#, options: .regularExpression) != nil
    }

    enum Problem: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return L("録音のファイルが見つかりません: \(name)")
            }
        }
    }

    /// 1 つを、選んでもらった名前で写す。同じ名前があれば置き換える
    /// （保存パネルが置き換えてよいかを確かめたあとに呼ぶ）。
    static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard MediaAccess.isReachable(source) else { throw Problem.missing(source.lastPathComponent) }
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else { return }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// まとめてフォルダへ写す。名前はもとのまま。フォルダに同じ名前があるときは
    /// 上書きせず、`rec-… 2.wav` のように番号を付ける（1 つずつ確かめてもらう
    /// 場面が無いので、黙って消さない）。
    ///
    /// - Returns: 写した先。sources と同じ順。
    @discardableResult
    static func copy(_ sources: [URL], into folder: URL) throws -> [URL] {
        let fm = FileManager.default
        // 先に全部あるかを見る。途中まで写して止まらないように。
        for source in sources where !MediaAccess.isReachable(source) {
            throw Problem.missing(source.lastPathComponent)
        }
        var written: [URL] = []
        for source in sources {
            let destination = freeName(for: source.lastPathComponent, in: folder)
            try fm.copyItem(at: source, to: destination)
            written.append(destination)
        }
        return written
    }

    /// folder の中で空いている名前。`name.wav` → `name 2.wav` → `name 3.wav` …
    static func freeName(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }
}

extension EditorStore {

    /// このプロジェクトの録音。ids を渡すと、その中の録音だけ（素材の並び順）。
    func recordings(among ids: Set<UUID>? = nil) -> [MediaAsset] {
        project.assets.filter { asset in
            (ids?.contains(asset.id) ?? true)
                && RecordingExport.isRecording(asset, document: documentURL)
        }
    }

    /// 素材の実際の場所。
    func fileURL(of asset: MediaAsset) -> URL {
        asset.url(relativeTo: baseURL)
    }

    /// 録音をフォルダへ写す（パネルなし。置き場所は呼ぶ側が決めてある）。
    @discardableResult
    func exportRecordings(_ ids: Set<UUID>? = nil, into folder: URL) throws -> [URL] {
        try RecordingExport.copy(recordings(among: ids).map(fileURL(of:)), into: folder)
    }

    /// 録音を書き出す。1 つなら保存パネルで名前と場所を、いくつかあるなら
    /// フォルダを選んでもらう。キャンセルなら何もしない。
    func exportRecordingsWithPanel(_ ids: Set<UUID>) {
        let chosen = recordings(among: ids)
        guard let first = chosen.first else { return }
        do {
            if chosen.count == 1 {
                let source = fileURL(of: first)
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = source.lastPathComponent
                if let type = UTType(filenameExtension: source.pathExtension) {
                    panel.allowedContentTypes = [type]
                }
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try RecordingExport.copy(source, to: destination)
            } else {
                guard let folder = chooseRecordingExportFolder() else { return }
                try exportRecordings(Set(chosen.map(\.id)), into: folder)
            }
        } catch {
            presentError(L("書き出せませんでした"), error.localizedDescription)
        }
    }

    /// いくつかの録音をまとめて置くフォルダを、標準のパネルで選んでもらう。
    func chooseRecordingExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("録音を書き出すフォルダを選んでください")
        panel.prompt = L("書き出す")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 素材を Finder で選んで見せる。書類の中の録音は、パッケージの中身が開く。
    func revealInFinder(_ ids: Set<UUID>) {
        let urls = project.assets.filter { ids.contains($0.id) }.map(fileURL(of:))
            .filter(MediaAccess.isReachable)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
