import AppKit
import Foundation

/// クリップボードに載せる中身。
///
/// クリップだけでは貼り付け先で復元できない。テキストはテンプレートを、
/// 映像や音声は素材の参照を必要とするので、参照しているぶんを一緒に運ぶ。
/// 別のプロジェクトへ貼っても中身が消えないようにするため。
struct ClipboardPayload: Codable {
    struct Entry: Codable {
        var clip: Clip
        /// 元のトラック。貼り付け先を選ぶ手がかりにする。
        var trackName: String
        var trackKind: TrackKind
    }

    var entries: [Entry]
    var assets: [MediaAsset]
    var templates: [TextTemplate]

    /// いちばん早いクリップの開始位置。ここを貼り付け位置に合わせる。
    var anchor: Double { entries.map(\.clip.start).min() ?? 0 }

    var isEmpty: Bool { entries.isEmpty }
}

enum ClipboardIO {
    static let pasteboardType = NSPasteboard.PasteboardType("com.hashrock.nanovid.clips")

    static func write(_ payload: ClipboardPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func read() -> ClipboardPayload? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(ClipboardPayload.self, from: data)
    }

    /// メニューの有効・無効を出すための軽い判定。
    static var hasClips: Bool {
        NSPasteboard.general.types?.contains(pasteboardType) ?? false
    }
}

extension EditorStore {

    // MARK: - コピーと切り取り

    /// 選択したクリップを、参照しているテンプレートと素材ごとクリップボードへ。
    func copySelection() {
        guard let payload = makePayload(of: selectedClipIDs) else { return }
        ClipboardIO.write(payload)
    }

    func cutSelection() {
        guard let payload = makePayload(of: selectedClipIDs) else { return }
        ClipboardIO.write(payload)
        deleteSelection()
    }

    /// 選択から中身を組み立てる。クリップボードを経由せずに試せるよう分けてある。
    func makePayload(of ids: Set<UUID>) -> ClipboardPayload? {
        guard !ids.isEmpty else { return nil }
        var entries: [ClipboardPayload.Entry] = []
        for track in project.tracks {
            for clip in track.clips where ids.contains(clip.id) {
                entries.append(.init(clip: clip, trackName: track.name, trackKind: track.kind))
            }
        }
        guard !entries.isEmpty else { return nil }

        let assetIDs = Set(entries.compactMap { $0.clip.content.assetID })
        let templateIDs = Set(entries.compactMap { $0.clip.content.textInstance?.templateID })
        return ClipboardPayload(
            entries: entries.sorted { $0.clip.start < $1.clip.start },
            assets: project.assets.filter { assetIDs.contains($0.id) },
            templates: project.textTemplates.filter { templateIDs.contains($0.id) }
        )
    }

    // MARK: - 貼り付け

    var canPaste: Bool { ClipboardIO.hasClips }

    /// 再生ヘッドの位置に貼る。
    func paste() {
        guard let payload = ClipboardIO.read() else { return }
        paste(payload)
    }

    /// 中身を再生ヘッドの位置に貼る。互いの位置関係は保つ。
    func paste(_ payload: ClipboardPayload) {
        guard !payload.isEmpty else { return }
        let at = project.canvas.snap(max(0, currentTime))
        let anchor = payload.anchor
        var pasted: Set<UUID> = []

        edit { p in
            // 参照しているぶんを先に取り込む。すでにあるものは触らない。
            for asset in payload.assets where !p.assets.contains(where: { $0.id == asset.id }) {
                p.assets.append(asset)
            }
            for template in payload.templates
            where !p.textTemplates.contains(where: { $0.id == template.id }) {
                p.textTemplates.append(template)
            }

            for entry in payload.entries {
                guard let trackIndex = Self.pasteTarget(for: entry, in: p,
                                                        preferring: selectedTrackID) else { continue }
                var clip = entry.clip
                clip.id = UUID()
                clip.start = p.canvas.snap(max(0, at + (entry.clip.start - anchor)))
                p.tracks[trackIndex].clips.append(clip)
                pasted.insert(clip.id)
            }
            p.tracks.indices.forEach { p.tracks[$0].sortClips() }
        }

        if !pasted.isEmpty {
            selectedClipIDs = pasted
        }
    }

    /// 貼り付け先のトラックを決める。
    /// 元と同じ名前のトラック → 選択中のトラック → 同じ種類の最初のトラック、の順。
    static func pasteTarget(for entry: ClipboardPayload.Entry,
                            in project: Project,
                            preferring selected: UUID?) -> Int? {
        let usable = { (track: Track) in track.kind == entry.trackKind && !track.isLocked }

        if let i = project.tracks.firstIndex(where: { usable($0) && $0.name == entry.trackName }) {
            return i
        }
        if let selected,
           let i = project.tracks.firstIndex(where: { usable($0) && $0.id == selected }) {
            return i
        }
        return project.tracks.firstIndex(where: usable)
    }
}
