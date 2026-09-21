import AVFoundation
import SwiftUI

struct ContentView: View {
    @Bindable var store: EditorStore

    @State private var recorder = AudioRecorder()
    @State private var showExport = false
    @State private var editingTemplateID: UUID?
    /// 録音を始めたときの再生ヘッド位置。止めたらそこへ置く。
    @State private var recordingAnchor: Double = 0

    // レイアウト。素材パネルは使う場面が限られるので既定では閉じておく。
    @State private var showLibrary = false
    @State private var showInspector = true
    @State private var libraryWidth: CGFloat = 230
    @State private var inspectorWidth: CGFloat = 290
    /// 下段の高さ。窓を広げたぶんは上段（プレビュー）に回したいので、
    /// 上段ではなく下段の高さを持つ。
    @State private var bottomHeight: CGFloat = 240
    @State private var bottomTab: BottomTab = .timeline

    private let topMinHeight: CGFloat = 220
    private let bottomMinHeight: CGFloat = 130

    var body: some View {
        GeometryReader { geo in
            let bottom = resolvedBottomHeight(in: geo.size.height)
            VStack(spacing: 0) {
                // 念のため、はみ出しても隣のペインへ漏れないようにしておく。
                topPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                PaneDivider.Horizontal(
                    bottomHeight: $bottomHeight,
                    range: bottomMinHeight...max(bottomMinHeight,
                                                 geo.size.height - topMinHeight))
                bottomPane
                    .frame(height: bottom, alignment: .top)
                    .clipped()
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(store.project.name + (store.hasUnsavedChanges ? " — 編集中" : ""))
        .sheet(isPresented: $showExport) { ExportView(store: store) }
        .sheet(item: Binding(
            get: { editingTemplateID.map { IdentifiedUUID(id: $0) } },
            set: { editingTemplateID = $0?.id }
        )) { wrapped in
            TemplateEditorView(store: store, templateID: wrapped.id)
        }
        .alert("エラー", isPresented: Binding(
            get: { store.buildError != nil },
            set: { if !$0 { store.buildError = nil } }
        )) {
            Button("OK") { store.buildError = nil }
        } message: {
            Text(store.buildError ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .focusedSceneValue(\.editorStore, store)
    }

    /// 窓が縮んでも上段が潰れないように収める。
    private func resolvedBottomHeight(in total: CGFloat) -> CGFloat {
        let available = max(bottomMinHeight, total - topMinHeight)
        return min(max(bottomHeight, bottomMinHeight), available)
    }

    // MARK: - 上段

    private var topPane: some View {
        HStack(spacing: 0) {
            if showLibrary {
                LibraryView(store: store, editingTemplateID: $editingTemplateID)
                    .frame(width: libraryWidth)
                PaneDivider.Vertical(width: $libraryWidth, range: 180...400)
            }

            VStack(spacing: 0) {
                PreviewPane(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                transport
            }
            .frame(maxWidth: .infinity)

            if showInspector {
                PaneDivider.Vertical(width: $inspectorWidth, range: 240...460, trailing: true)
                InspectorView(store: store)
                    .frame(width: inspectorWidth)
            }
        }
    }

    // MARK: - 下段

    @ViewBuilder
    private var bottomPane: some View {
        switch bottomTab {
        case .timeline:
            TimelineView(store: store, bottomTab: $bottomTab)
        case .text:
            TextClipsPane(store: store, bottomTab: $bottomTab)
        }
    }

    // MARK: - 再生操作

    private var transport: some View {
        HStack(spacing: 14) {
            Button { store.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
            Button { store.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { store.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
            Button { store.seek(to: store.duration) } label: { Image(systemName: "forward.end.fill") }

            Divider().frame(height: 16)

            Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                .font(.system(.callout, design: .monospaced))

            if store.isBuilding {
                ProgressView().controlSize(.small)
            }

            Spacer()

            recordingControl
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var recordingControl: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                LevelMeter(level: recorder.level)
                    .frame(width: 60, height: 8)
            }
            Button {
                toggleRecording()
            } label: {
                Label(recorder.isRecording ? "停止" : "録音",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle")
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
            }
            .labelStyle(.titleAndIcon)
            .help("マイクから録音してタイムラインに置く")
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            guard let url = recorder.stop() else { return }
            Task { @MainActor in
                let assets = await store.importAssets(urls: [url])
                guard let asset = assets.first,
                      let track = store.project.tracks.last(where: { $0.kind == .audio })
                        ?? store.project.tracks.first(where: { $0.kind == .audio }) else { return }
                store.addMediaClip(assetID: asset.id, trackID: track.id, at: recordingAnchor)
            }
        } else {
            store.pause()
            recordingAnchor = store.currentTime
            let url = store.recordingURL()
            Task { @MainActor in
                let ok = await recorder.start(to: url)
                if !ok, case .denied = recorder.state {
                    store.buildError = "マイクへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で許可してください。"
                }
            }
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showLibrary.toggle() }
            } label: {
                Label("素材パネル", systemImage: "sidebar.leading")
            }
            .help("素材とテンプレートのパネルを開閉 (⌘1)")
            .keyboardShortcut("1", modifiers: .command)
        }
        ToolbarItem(placement: .navigation) {
            Button { store.openProject() } label: { Label("開く", systemImage: "folder") }
        }
        ToolbarItem {
            Button { store.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
        }
        ToolbarItem {
            Button { showExport = true } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .disabled(store.duration <= 0)
        }
        ToolbarItem {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showInspector.toggle() }
            } label: {
                Label("インスペクタ", systemImage: "sidebar.trailing")
            }
            .help("右のパネルを開閉 (⌘2)")
            .keyboardShortcut("2", modifiers: .command)
        }
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                   let decoded = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(decoded)
                }
            }
            guard !urls.isEmpty else { return }
            if let projectFile = urls.first(where: { $0.pathExtension == ProjectIO.fileExtension }) {
                store.open(url: projectFile)
            } else {
                await store.importAndAppend(urls: urls)
            }
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// 録音中の入力レベル表示。
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.92 ? Color.red : Color.green)
                    .frame(width: geo.size.width * min(1, level))
            }
        }
    }
}

// MARK: - メニューからストアへ届けるための橋渡し

struct EditorStoreFocusKey: FocusedValueKey {
    typealias Value = EditorStore
}

extension FocusedValues {
    var editorStore: EditorStore? {
        get { self[EditorStoreFocusKey.self] }
        set { self[EditorStoreFocusKey.self] = newValue }
    }
}
