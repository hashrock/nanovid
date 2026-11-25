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

    // レイアウト。素材パネルもインスペクタも既定で閉じ、⌘1 / ⌘2 とツールバーで開閉する。
    // 選択に合わせて勝手に開閉すると、選ぶたびにプレビューの幅が変わって落ち着かない。
    @State private var showLibrary = false
    @State private var showInspector = false
    @State private var libraryWidth: CGFloat = 230
    @State private var inspectorWidth: CGFloat = 276
    /// 下段の高さ。窓を広げたぶんは上段（プレビュー）に回したいので、
    /// 上段ではなく下段の高さを持つ。
    /// 既定は、見出し行・ルーラー・3 トラック・横スクロールバーがちょうど収まる高さ
    /// （TimelineView の寸法から求める）。
    @State private var bottomHeight: CGFloat = TimelineView.fittingHeight(lanes: 3)
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
    ///   --shot-state <状態>[,<状態>…] select-text / select-media / select-audio / export / library / text-tab /
    ///                               seek:<秒> / select-at:<秒> / lanes:<本> / pps:<pt> / silence-cut / silence-menu / template-editor
    ///   --shot-size <幅>x<高さ>      窓の大きさ
    ///   --shot-appearance light|dark 外観（システムの設定を変えずに、このアプリだけ）
    ///   --shot-png <ディレクトリ>     状態を作ったあと、窓を 2 倍の画素で描いて書き出す（ShotCapture）
    ///   --shot-offscreen             窓を画面の外に置く（--shot-png と使う）
    @MainActor
    private func applyShotState() async {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--shot-appearance"), args.count > i + 1 {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let i = args.firstIndex(of: "--shot-size"), args.count > i + 1 {
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                // --shot-offscreen なら画面の外に置く（--shot-png で描くので、画面に出さなくてよい）。
                let origin = args.contains("--shot-offscreen") ? -20000.0 : 80
                window.setFrame(NSRect(x: origin, y: origin, width: parts[0], height: parts[1]), display: true)
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
        // カンマで区切って、いくつかの状態を順に重ねられる（例: silence-cut,select-at:1）。
        let states = args[i + 1].split(separator: ",").map(String.init)
        for state in states where state != "silence-menu" {
            await applyShotState(state)
        }
        if let j = args.firstIndex(of: "--shot-png"), args.count > j + 1 {
            try? await Task.sleep(for: .milliseconds(1500))
            await ShotCapture.write(to: URL(fileURLWithPath: args[j + 1]), store: store)
        }
        // メニューは開くと閉じるまで戻らないので、窓を描き終えてから最後に開く。
        if states.contains("silence-menu") {
            await applyShotState("silence-menu")
        }
    }

    @MainActor
    private func applyShotState(_ state: String) async {
        let clips = store.project.tracks.flatMap(\.clips)
        let parts = state.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? Double(parts[1]) : nil
        switch parts[0] {
        case "seek":
            if let value { store.seek(to: value) }
        case "lanes":
            // 下段の高さを、トラック n 本ぶんにする。
            if let value { bottomHeight = TimelineView.fittingHeight(lanes: Int(value)) }
        case "pps":
            // タイムラインの拡大率（1 秒あたりの pt）。
            if let value { store.pixelsPerSecond = value }
        case "select-at":
            // その時刻にかかる文字のクリップを選ぶ（並びの後ろのトラックを優先）。
            guard let value else { break }
            let hit = store.project.tracks.reversed().lazy.flatMap(\.clips).first { clip in
                if case .text = clip.content { clip.start <= value && value < clip.start + clip.duration } else { false }
            }
            if let hit {
                store.selectedClipIDs = [hit.id]
                store.seek(to: value)
                showInspector = true
            }
        case "silence-cut":
            _ = try? await store.cutSilence(options: .standard)
            try? await Task.sleep(for: .milliseconds(500))
        case "silence-menu":
            // 「編集操作 > 無音を詰める」の本物の項目を、タイムラインの見出し行の右に出す。
            // 開いたメニューは閉じずに残る（撮り終えたらアプリごと終わらせる）。
            // --shot-png では窓を 2 倍の画素で描くので、メニューも文字を 2 倍にして
            // 等倍で撮り、そのまま重ねられるようにする（--shot-menu-scale 2）。
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let content = window.contentView,
                  let actions = NSApp.mainMenu?.items.first(where: { $0.title == L("編集操作") })?.submenu,
                  let silence = actions.items.first(where: { $0.title == L("無音を詰める") })?.submenu
            else { break }
            // アプリを前に出さない（ユーザーの入力を奪わない）ので、本物の項目は「使えない」灰色で出る。
            // 同じ題の項目を、使える状態で並べ直して出す。
            let menu = NSMenu()
            for item in silence.items {
                let copy = NSMenuItem(title: item.title, action: #selector(ShotMenuTarget.noop), keyEquivalent: "")
                copy.target = ShotMenuTarget.shared
                menu.addItem(copy)
            }
            if let k = CommandLine.arguments.firstIndex(of: "--shot-menu-scale"),
               CommandLine.arguments.count > k + 1, let scale = Double(CommandLine.arguments[k + 1]) {
                menu.font = NSFont.menuFont(ofSize: NSFont.systemFontSize * scale)
            }
            // メニューは半透明で後ろが透けるので、無地の下敷きの窓の上で開く。
            // 撮ったメニューを、2 倍で描いた窓の「…」の下に重ねる。
            // マウスのポインタが重なると項目が選ばれた色になるので、ポインタから遠い隅に出す。
            let mouse = NSEvent.mouseLocation
            let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
                ?? window.frame
            let backdrop = NSWindow(
                contentRect: NSRect(x: mouse.x < screen.midX ? screen.maxX - 440 : screen.minX + 20,
                                    y: mouse.y < screen.midY ? screen.maxY - 240 : screen.minY + 20,
                                    width: 420, height: 220),
                styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(white: 0.97, alpha: 1)
            backdrop.isReleasedWhenClosed = false
            backdrop.orderFront(nil)
            ShotMenuTarget.backdrop = backdrop
            guard let base = backdrop.contentView else { break }
            let point = NSPoint(x: 40, y: base.isFlipped ? 40 : base.bounds.height - 40)
            DispatchQueue.main.async {
                menu.popUp(positioning: nil, at: point, in: base)
            }
        case "template-editor":
            showLibrary = true
            try? await Task.sleep(for: .milliseconds(300))
            let selected = clips.first { store.selectedClipIDs.contains($0.id) }
            if case .text(let instance)? = selected?.content {
                editingTemplateID = instance.templateID
            } else {
                editingTemplateID = store.project.textTemplates.last?.id
            }
        case "inspector":
            showInspector = true
        case "select-text":
            if let clip = clips.first(where: { if case .text = $0.content { true } else { false } }) {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
                showInspector = true
            }
        case "select-media":
            if let clip = clips.first(where: { if case .media = $0.content { true } else { false } }) {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
                showInspector = true
            }
        case "select-audio":
            if let track = store.project.tracks.first(where: { $0.kind == .audio }),
               let clip = track.clips.first {
                store.selectedClipIDs = [clip.id]
                store.seek(to: clip.start + 0.5)
                showInspector = true
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
        withAnimation(.easeInOut(duration: 0.16)) { showInspector.toggle() }
    }

    // MARK: - 上段

    private var topPane: some View {
        HStack(spacing: 0) {
            if showLibrary {
                LibraryView(store: store, editingTemplateID: $editingTemplateID)
                    .frame(width: libraryWidth)
                PaneDivider.Vertical(width: $libraryWidth, range: 180...400)
            }

            // 再生操作はプレビューの下に別の行を持たず、下段の見出し行に並べる
            // （TransportControls）。そのぶんの縦をプレビューに回す。
            PreviewPane(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
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
            TimelineView(store: store, bottomTab: $bottomTab, transport: AnyView(transport))
        case .text:
            TextClipsPane(store: store, bottomTab: $bottomTab, transport: AnyView(transport))
        }
    }

    // MARK: - 再生操作

    private var transport: some View {
        TransportControls(store: store, recorder: recorder, toggleRecording: toggleRecording)
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

/// 再生操作。下段の見出し行（タイムライン・字幕のどちらのタブでも）に並べる。
///
/// 再生とコマ送り、時刻だけを置く。先頭へ・末尾へは「編集操作」メニューから。
/// 録音もここに置く。録音中はレベルと停止を出す。
struct TransportControls: View {
    @Bindable var store: EditorStore
    let recorder: AudioRecorder
    let toggleRecording: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { store.step(frames: -1) } label: {
                    Image(systemName: "backward.frame.fill").font(.caption).foregroundStyle(.secondary)
                }
                .help("1 フレーム戻る (←)")
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .help("再生 / 一時停止 (Space)")
                Button { store.step(frames: 1) } label: {
                    Image(systemName: "forward.frame.fill").font(.caption).foregroundStyle(.secondary)
                }
                .help("1 フレーム進む (→)")
            }

            HStack(spacing: 4) {
                Text(Format.timecode(store.currentTime, fps: store.project.canvas.fps))
                    .font(.system(.callout, design: .monospaced))
                Text("/ \(Format.timecode(store.duration, fps: store.project.canvas.fps))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .fixedSize()

            if store.isBuilding {
                ProgressView().controlSize(.small)
            }

            recordingControl
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var recordingControl: some View {
        if recorder.isRecording {
            LevelMeter(level: recorder.level)
                .frame(width: 48, height: 6)
            Button(action: toggleRecording) {
                Image(systemName: "stop.circle.fill").foregroundStyle(Color.red)
            }
            .help("録音を停止")
        } else {
            Button(action: toggleRecording) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .help("マイクから録音してタイムラインに置く")
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
