import AppKit
import Foundation

/// プロジェクトファイルの新規・開く・保存。
extension EditorStore {

    func newProject() {
        guard confirmDiscardIfNeeded() else { return }
        pause()
        documentURL = nil
        MediaAccess.shared.releaseAll()
        project = .starter()
        selectedClipIDs = []
        currentTime = 0
        hasUnsavedChanges = false
        resetHistory()
        AssetCache.shared.removeAll()
        TextRasterizer.shared.invalidateAll()
    }

    func openProject() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectIO.openableTypes
        // パッケージは 1 つの書類として選ぶ（中へ潜らせない）。
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            var loaded = try ProjectIO.load(from: url)
            pause()
            // 前のプロジェクトの素材の権限を手放して、こちらの分を取り戻す。
            let relocated = MediaAccess.shared.activate(&loaded, base: url.deletingLastPathComponent())
            documentURL = url
            project = loaded
            selectedClipIDs = []
            currentTime = 0
            // 素材が動いていて path を書き換えたときは、保存し直してもらう。
            hasUnsavedChanges = relocated
            resetHistory()
            TextRasterizer.shared.invalidateAll()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            presentError(L("開けませんでした"), error.localizedDescription)
            return
        }
        // 起動直後（--open や、書類を開いて起動したとき）にその場で runModal すると、
        // アプリの立ち上げが済んでいないため表示されずに abort で戻ってくる。
        // 次のランループに回して、窓が出てから聞く。
        DispatchQueue.main.async { [self] in offerToLocateMissingMedia() }
    }

    /// 開いたプロジェクトに読めない素材があれば、素材のフォルダを選ぶよう勧める。
    ///
    /// 起きるのは、以前の版（bookmark を持たない）で保存したプロジェクトを
    /// Sandbox の下で開いたときや、別の Mac から持ってきたとき。
    private func offerToLocateMissingMedia() {
        // テストは片付けたあとの一時フォルダを指したまま走り終えることがある。
        // 誰も押せないアラートで止まらないようにする。
        guard !NanovidApp.isRunningTests else { return }
        let missing = MediaAccess.unreachable(in: project, base: baseURL)
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("\(missing.count) 個の素材を開けません")
        alert.informativeText = L("素材の入ったフォルダを選ぶと読めるようになります。選んだあとに保存すると、次からはそのまま開けます。")
        alert.addButton(withTitle: L("フォルダを選ぶ…"))
        alert.addButton(withTitle: L("あとで"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        locateMissingMedia()
    }

    /// 読めない素材を、選んでもらったフォルダから探し直す。
    ///
    /// パネルで選んだフォルダの権限はこのセッション限りなので、見つけた素材ごとに
    /// bookmark を作り直して持ち越す。探す場所は、記録してある path そのもの
    /// （フォルダの権限で読めるようになる）と、選んだフォルダ直下の同じ名前のファイル。
    func locateMissingMedia() {
        let missing = MediaAccess.unreachable(in: project, base: baseURL)
        guard !missing.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = baseURL
        panel.message = L("素材の入ったフォルダを選んでください")
        panel.prompt = L("選ぶ")
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var copy = project
        var found = 0
        for i in copy.assets.indices where missing.contains(where: { $0.id == copy.assets[i].id }) {
            let recorded = copy.assets[i].url(relativeTo: baseURL)
            let candidates = [recorded, folder.appendingPathComponent(recorded.lastPathComponent)]
            guard let hit = candidates.first(where: MediaAccess.isReachable) else { continue }
            copy.assets[i].path = hit.path
            copy.assets[i].bookmark = MediaBookmark.make(for: hit)
            found += 1
        }
        if found > 0 {
            AssetCache.shared.removeAll()
            project = copy
        }
        if found < missing.count {
            presentError(L("見つからない素材があります"),
                         L("\(missing.count - found) 個の素材は選んだフォルダにありませんでした。"))
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = documentURL else { return saveAs() }
        do {
            // 古い 1 ファイルの形式を開いていたときは、ここでパッケージに置き換わる。
            try ProjectIO.save(project, to: url, previous: url)
            hasUnsavedChanges = false
            return true
        } catch {
            presentError(L("保存できませんでした"), error.localizedDescription)
            return false
        }
    }

    /// - Parameter message: 保存パネルに出す説明。録音の前に保存してもらうときに使う。
    @discardableResult
    func saveAs(message: String? = nil) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectIO.contentType]
        panel.nameFieldStringValue = "\(project.name).\(ProjectIO.fileExtension)"
        if let message { panel.message = message }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return saveAs(to: url)
    }

    /// 別の場所へ保存して、そちらを開いている書類にする。
    @discardableResult
    func saveAs(to url: URL) -> Bool {
        do {
            // 書類の中の録音は新しい書類へ写り、素材の path は保存先が基準になる。
            let saved = try ProjectIO.save(project, to: url, previous: documentURL)
            project.assets = saved.assets
            AssetCache.shared.removeAll()
            documentURL = url
            project.name = url.deletingPathExtension().lastPathComponent
            hasUnsavedChanges = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            presentError(L("保存できませんでした"), error.localizedDescription)
            return false
        }
    }

    /// 未保存の変更があるときだけ確認する。続行してよければ true。
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }
        return handleDiscardResponse(Self.discardAlert().runModal())
    }

    /// confirmDiscardIfNeeded の、窓にシートで出す版。窓を閉じる・終了するときに
    /// 使う。窓は閉じずに残したまま聞き、続行してよければ true を渡す。
    func confirmDiscardIfNeeded(in window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges else { return completion(true) }
        Self.discardAlert().beginSheetModal(for: window) { response in
            completion(self.handleDiscardResponse(response))
        }
    }

    private static func discardAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("保存していない変更があります")
        alert.informativeText = L("変更を保存しますか？")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("保存しない"))
        alert.addButton(withTitle: L("キャンセル"))
        return alert
    }

    private func handleDiscardResponse(_ response: NSApplication.ModalResponse) -> Bool {
        switch response {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func presentError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// 録音ファイルの保存先。決まらなければ nil（録音を始めない）。
    ///
    /// 録音は書類（.nanovid パッケージ）の中の Recordings/ に置く。書類の中なら
    /// App Sandbox の下でもいつでも書けるので、保存先を別に選んでもらう必要がない。
    /// 決め打ちの場所（~/Movies など）にも置かない（App Review 2.4.5(i)）。
    ///
    /// 置き場が要るので、まだ保存していないプロジェクトは先に保存してもらう。
    /// 古い 1 ファイルの形式を開いているときは、その場でパッケージに保存し直す。
    func recordingURL() -> URL? {
        guard let package = packageForRecording() else { return nil }
        let dir = ProjectIO.recordingsDirectory(in: package)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            presentError(L("録音を始められませんでした"), error.localizedDescription)
            return nil
        }
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        return dir.appendingPathComponent("rec-\(stamp).wav")
    }

    private func packageForRecording() -> URL? {
        if let url = documentURL, ProjectIO.isPackage(url) { return url }
        let saved = documentURL == nil
            ? saveAs(message: L("録音はプロジェクトの中に保存されます。先にプロジェクトの保存先を選んでください。"))
            : save()
        guard saved, let url = documentURL, ProjectIO.isPackage(url) else { return nil }
        return url
    }
}

extension DateFormatter {
    static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
