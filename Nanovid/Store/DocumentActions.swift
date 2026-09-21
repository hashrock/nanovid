import AppKit
import Foundation

/// プロジェクトファイルの新規・開く・保存。
extension EditorStore {

    func newProject() {
        guard confirmDiscardIfNeeded() else { return }
        pause()
        documentURL = nil
        project = .starter()
        selectedClipIDs = []
        currentTime = 0
        hasUnsavedChanges = false
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
            let loaded = try ProjectIO.load(from: url)
            pause()
            documentURL = url
            project = loaded
            selectedClipIDs = []
            currentTime = 0
            hasUnsavedChanges = false
            TextRasterizer.shared.invalidateAll()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            presentError("開けませんでした", error.localizedDescription)
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
            presentError("保存できませんでした", error.localizedDescription)
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
            presentError("保存できませんでした", error.localizedDescription)
            return false
        }
    }

    /// 未保存の変更があるときだけ確認する。続行してよければ true。
    private func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "保存していない変更があります"
        alert.informativeText = "変更を保存しますか？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")
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

    /// 録音ファイルの保存先。プロジェクトの隣に Recordings/ を作る。
    func recordingURL() -> URL {
        let base = baseURL
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        return dir.appendingPathComponent("rec-\(stamp).wav")
    }
}

extension DateFormatter {
    static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
