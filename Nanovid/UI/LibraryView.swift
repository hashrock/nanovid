import SwiftUI

struct LibraryView: View {
    @Bindable var store: EditorStore
    @Binding var editingTemplateID: UUID?

    enum Tab: String, CaseIterable, Identifiable {
        case assets, templates
        var id: String { rawValue }
        var label: String { self == .assets ? L("素材") : L("テンプレート") }
    }

    @State private var tab: Tab = .assets
    /// 素材の一覧で選んでいるもの。まとめて書き出す・取り除くのに使う。
    @State private var selectedAssetIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch tab {
            case .assets: assetList
            case .templates: templateList
            }
        }
        .frame(minWidth: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 素材

    private var assetList: some View {
        VStack(spacing: 0) {
            // 空のときは何も出さない。狭い幅で不格好に折り返すうえ、
            // 下の「読み込む」とドロップで十分わかる。
            List(selection: $selectedAssetIDs) {
                ForEach(store.project.assets) { asset in
                    AssetRow(asset: asset, fps: store.project.canvas.fps)
                        .contentShape(Rectangle())
                }
            }
            .listStyle(.inset)
            // 右クリックは「選んでいるもの全部」か「選んでいない 1 行」に効く
            // （Finder と同じ）。ダブルクリックは置く。
            .contextMenu(forSelectionType: UUID.self) { ids in
                assetMenu(for: ids)
            } primaryAction: { ids in
                assets(ids).forEach(place)
            }

            Divider()
            HStack {
                Button {
                    importFiles()
                } label: {
                    Label("読み込む", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { @MainActor in _ = await store.importAssets(urls: urls) }
            return true
        }
    }

    private func assets(_ ids: Set<UUID>) -> [MediaAsset] {
        store.project.assets.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func assetMenu(for ids: Set<UUID>) -> some View {
        let chosen = assets(ids)
        if !chosen.isEmpty {
            Button("再生ヘッドの位置に置く") { chosen.forEach(place) }
            Divider()
            // 録音は書類の中にあって Finder からは見えないので、外へ写す入口を置く。
            // 以前の版が書類の外に置いた録音にも同じように効く。
            let recordings = store.recordings(among: ids)
            if recordings.count == 1 {
                Button("録音を書き出す…") { store.exportRecordingsWithPanel(ids) }
            } else if recordings.count > 1 {
                Button("\(recordings.count) 個の録音を書き出す…") { store.exportRecordingsWithPanel(ids) }
            }
            Button("Finder で表示") { store.revealInFinder(ids) }
            Divider()
            Button("素材を取り除く", role: .destructive) { chosen.forEach(remove) }
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ProjectIO.mediaTypes
        panel.message = L("動画・音声・画像を選んでください")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in _ = await store.importAssets(urls: urls) }
    }

    /// 再生ヘッドの位置に、種類に合ったトラックへ置く。
    private func place(_ asset: MediaAsset) {
        let wantedKind: TrackKind = asset.kind == .audio ? .audio : .video
        let candidate = store.selectedTrackID.flatMap { id in
            store.project.tracks.first { $0.id == id && $0.kind == wantedKind }
        } ?? store.project.tracks.first { $0.kind == wantedKind }
        guard let track = candidate else { return }
        store.addMediaClip(assetID: asset.id, trackID: track.id, at: store.currentTime)
    }

    private func remove(_ asset: MediaAsset) {
        let inUse = store.project.tracks.contains { t in
            t.clips.contains { $0.content.assetID == asset.id }
        }
        if inUse {
            store.buildError = L("タイムラインで使用中の素材は取り除けません。")
            return
        }
        store.edit { $0.assets.removeAll { $0.id == asset.id } }
        selectedAssetIDs.remove(asset.id)
    }

    // MARK: - テンプレート

    private var templateList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.project.textTemplates) { template in
                    TemplateRow(template: template,
                                usageCount: store.project.textClips(usingTemplate: template.id).count)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { placeText(template) }
                        .contextMenu {
                            Button("再生ヘッドの位置に置く") { placeText(template) }
                            Button("レイアウトを編集…") { editingTemplateID = template.id }
                            Button("複製") { store.duplicateTemplate(template.id) }
                            Divider()
                            Button("削除", role: .destructive) { store.removeTemplate(template.id) }
                        }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button {
                    let new = TextTemplate(
                        name: "新しいテンプレート",
                        nodes: [TemplateNode(name: "本文", kind: .text(TextNodeSpec(text: .prop("text"))))],
                        props: [PropDef(key: "text", label: "テキスト", type: .string,
                                        defaultValue: .string(L("ここにテキスト")))]
                    )
                    store.upsertTemplate(new)
                    editingTemplateID = new.id
                } label: {
                    Label("新規", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private func placeText(_ template: TextTemplate) {
        let candidate = store.selectedTrackID.flatMap { id in
            store.project.tracks.first { $0.id == id && $0.kind == .video }
        } ?? store.project.tracks.last { $0.kind == .video }
        guard let track = candidate else { return }
        store.addTextClip(templateID: template.id, trackID: track.id, at: store.currentTime)
    }
}

// MARK: - 行

private struct AssetRow: View {
    let asset: MediaAsset
    let fps: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.displayName).font(.caption).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch asset.kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }

    private var detail: String {
        var parts: [String] = [asset.kind.label]
        if asset.kind != .image { parts.append(Format.duration(asset.duration)) }
        if let s = asset.naturalSize {
            parts.append("\(Int(s.width))×\(Int(s.height))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct TemplateRow: View {
    let template: TextTemplate
    let usageCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(LName(template.name)).font(.caption).lineLimit(1)
                Text("\(template.props.count) props · 使用 \(usageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
