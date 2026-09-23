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
        panel.allowedContentTypes = [ProjectIO.contentType]
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
            try ProjectIO.save(project, to: url)
            hasUnsavedChanges = false
            return true
        } catch {
            presentError(L("保存できませんでした"), error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectIO.contentType]
        panel.nameFieldStringValue = "\(project.name).\(ProjectIO.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try ProjectIO.save(project, to: url)
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
    private func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = L("保存していない変更があります")
        alert.informativeText = L("変更を保存しますか？")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("保存しない"))
        alert.addButton(withTitle: L("キャンセル"))
        switch alert.runModal() {
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

    /// 録音ファイルの保存先。
    ///
    /// 書けるならプロジェクトの隣の Recordings/（フォルダごと持ち運べる）。
    /// Sandbox の下ではプロジェクトのフォルダに書く権利が無いので、ムービー
    /// フォルダの下に置く（com.apple.security.assets.movies.read-write）。
    func recordingURL() -> URL {
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        return recordingsDirectory().appendingPathComponent("rec-\(stamp).wav")
    }

    private func recordingsDirectory() -> URL {
        let fm = FileManager.default
        if let base = baseURL {
            let dir = base.appendingPathComponent("Recordings", isDirectory: true)
            // 既にフォルダがあっても書けるとは限らない。isWritableFile は Sandbox の
            // 拒否を見ないので、実際に置いてみて確かめる。
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               Self.canWrite(into: dir) {
                return dir
            }
        }
        return Self.userMoviesDirectory.appendingPathComponent("Nanovid Recordings", isDirectory: true)
    }

    private static func canWrite(into dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".nanovid-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// 本物の ~/Movies。Sandbox の下では FileManager の moviesDirectory が
    /// コンテナの中を指し、そこに置くとユーザーから見えなくなるので、
    /// ホームを自前で引いて組み立てる。
    static var userMoviesDirectory: URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
                .appendingPathComponent("Movies", isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

extension DateFormatter {
    static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
