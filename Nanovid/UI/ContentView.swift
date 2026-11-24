import AVFoundation
import SwiftUI

/// 窓とアプリメニューのあいだで共有する、その場限りの画面状態。
@Observable
final class WindowSession {
    var showExport = false
    var showProjectSettings = false
    var toggleRecordingCount = 0
    var isRecording = false
}

struct ContentView: View {
    @Bindable var store: EditorStore
    @Bindable var session: WindowSession

    @State private var recorder = AudioRecorder()
    @State private var editingTemplateID: UUID?
    /// 録音を始めたときの再生ヘッド位置。止めたらそこへ置く。
    @State private var recordingAnchor: Double = 0
    @State private var isTransportHovered = false

    // レイアウト。素材パネルは既定で閉じ、インスペクタはクリップ選択中だけ自動表示する。
    @State private var showLibrary = false
    /// nil は自動（選択中だけ表示）、true/false はユーザーの手動開閉。
    @State private var inspectorOverride: Bool?
    @State private var libraryWidth: CGFloat = 230
    @State private var inspectorWidth: CGFloat = 276
    /// 下段の高さ。窓を広げたぶんは上段（プレビュー）に回したいので、
    /// 上段ではなく下段の高さを持つ。
    @State private var bottomHeight: CGFloat = 240
    @State private var bottomTab: BottomTab = .timeline

    private let topMinHeight: CGFloat = 220
    private let bottomMinHeight: CGFloat = 130

    private var isInspectorShown: Bool {
        inspectorOverride ?? !store.selectedClipIDs.isEmpty
    }

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
        .navigationTitle(store.project.name + (store.hasUnsavedChanges ? L(" — 編集中") : ""))
        .sheet(isPresented: $session.showExport) { ExportView(store: store) }
        .sheet(isPresented: $session.showProjectSettings) { ProjectSettingsSheet(store: store) }
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
        .onChange(of: store.selectedClipIDs.isEmpty) { _, isEmpty in
            // 選択中に手動で閉じていた場合、選択を解いたら自動モードに戻す。
            if isEmpty, inspectorOverride == false {
                inspectorOverride = nil
            }
        }
        .onChange(of: session.toggleRecordingCount) { _, _ in
            toggleRecording()
        }
        .onChange(of: recorder.isRecording) { _, active in
            session.isRecording = active
        }
        .focusedSceneValue(\.editorStore, store)
        #if DEBUG
        .task { await applyShotState() }
        #endif
    }

    #if DEBUG
    /// スクリーンショット用（デバッグビルドだけ）。本物のクリックを送らずに、
    /// 起動引数で画面の状態を作る。
    ///
    ///   --shot-media <ファイル>...   取り込んでタイムラインに並べる（-- で始まる引数まで）
    ///   --shot-state <状態>          select-text / select-media / select-audio / export / library / text-tab
    ///   --shot-size <幅>x<高さ>      窓の大きさ
    @MainActor
    private func applyShotState() async {
        let args = CommandLine.arguments
        try? await Task.sleep(for: .milliseconds(300))
        if let i = args.firstIndex(of: "--shot-size"), args.count > i + 1 {
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.setFrame(NSRect(x: 80, y: 80, width: parts[0], height: parts[1]), display: true)
            }
        }
        if let i = args.firstIndex(of: "--shot-media") {
            let urls = args[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            // --open の読み込みが済んでから足す。
            try? await Task.sleep(for: .milliseconds(300))
            let assets = await store.importAssets(urls: urls)
            // 映像と画像は、テロップの無い映像トラックへ順に並べる。
            var cursor: [UUID: Double] = [:]
            for asset in assets {
                let kind: TrackKind = asset.kind == .audio ? .audio : .video
                guard let track = store.project.tracks.first(where: { t in
                    t.kind == kind && !t.clips.contains { if case .text = $0.content { true } else { false } }
                }) else { continue }
                let at = cursor[track.id] ?? track.duration
                store.addMediaClip(assetID: asset.id, trackID: track.id, at: at)
                cursor[track.id] = at + (asset.kind == .image ? 5 : asset.duration)
            }
        }
        guard let i = args.firstIndex(of: "--shot-state"), args.count > i + 1 else { return }
        try? await Task.sleep(for: .milliseconds(500))
        let clips = store.project.tracks.flatMap(\.clips)
        switch args[i + 1] {
        case "select-text":
            if let clip = clips.first(where: { if case .text = $0.content { true } else { false } }) {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
            }
        case "select-media":
            if let clip = clips.first(where: { if case .media = $0.content { true } else { false } }) {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
            }
        case "select-audio":
            if let track = store.project.tracks.first(where: { $0.kind == .audio }),
               let clip = track.clips.first {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
            }
        case "export": session.showExport = true
        case "library": showLibrary = true
        case "text-tab": bottomTab = .text
        default: break
        }
    }
    #endif

    /// 窓が縮んでも上段が潰れないように収める。
    private func resolvedBottomHeight(in total: CGFloat) -> CGFloat {
        let available = max(bottomMinHeight, total - topMinHeight)
        return min(max(bottomHeight, bottomMinHeight), available)
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.16)) {
            if isInspectorShown {
                inspectorOverride = store.selectedClipIDs.isEmpty ? nil : false
            } else {
                inspectorOverride = store.selectedClipIDs.isEmpty ? true : nil
            }
        }
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

            if isInspectorShown {
                PaneDivider.Vertical(width: $inspectorWidth, range: 240...420, trailing: true)
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
        ZStack {
            HStack(spacing: 6) {
                Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                Text("/ \(Format.timecode(store.duration, fps: store.project.canvas.fps))")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if store.isBuilding {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }

                Spacer()

                recordingControl
            }

            HStack(spacing: 12) {
                Group {
                    Button { store.seek(to: 0) } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("先頭へ")
                    Button { store.step(frames: -1) } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .help("1 フレーム戻る (←)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(isTransportHovered ? 1 : 0)
                .allowsHitTesting(isTransportHovered)

                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("再生 / 一時停止 (Space)")

                Group {
                    Button { store.step(frames: 1) } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .help("1 フレーム進む (→)")
                    Button { store.seek(to: store.outputEnd) } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("末尾へ")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(isTransportHovered ? 1 : 0)
                .allowsHitTesting(isTransportHovered)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.14)) {
                isTransportHovered = inside
            }
        }
    }

    private var recordingControl: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                LevelMeter(level: recorder.level)
                    .frame(width: 60, height: 8)
                Button {
                    toggleRecording()
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .foregroundStyle(Color.red)
                }
                .labelStyle(.titleAndIcon)
                .help("録音を停止")
            } else {
                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: "mic")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .help("マイクから録音してタイムラインに置く")
            }
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
            // 録音は書類の中に置く。未保存なら先に保存してもらい、キャンセルなら録音しない。
            guard let url = store.recordingURL() else { return }
            recordingAnchor = store.currentTime
            Task { @MainActor in
                let ok = await recorder.start(to: url)
                if !ok, case .denied = recorder.state {
                    store.buildError = L("マイクへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で許可してください。")
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
        if store.isCuttingSilence {
            ToolbarItem {
                ProgressView()
                    .controlSize(.small)
                    .help("無音を詰めています")
            }
        }
        ToolbarItem {
            // 「ファイル > 音声を書き出す」が動いているあいだは、進み具合を出す。
            if let progress = store.audioExportProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("音声を書き出しています")
            } else {
                Button { session.showExport = true } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .help("動画を書き出す (⌘E)")
                .disabled(store.duration <= 0)
            }
        }
        ToolbarItem {
            Button(action: toggleInspector) {
                Label("インスペクタ", systemImage: "sidebar.trailing")
            }
            .help("インスペクタを開閉 (⌘2)")
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
