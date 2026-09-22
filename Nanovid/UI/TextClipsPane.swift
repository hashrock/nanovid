import SwiftUI

/// 画面下段の「字幕」タブ。テキストクリップを表で一覧し、まとめて打ち替える。
///
/// モーダルにしないのが肝。字幕は打ちながらプレビューで確かめるものなので、
/// 別ウィンドウに隠してしまうと確認のたびに閉じることになる。
struct TextClipsPane: View {
    @Bindable var store: EditorStore
    @Binding var bottomTab: BottomTab

    @State private var templateFilter: UUID?
    @State private var checked: Set<UUID> = []
    @State private var transcriptionLocale = Locale(identifier: "ja-JP")

    private var rows: [Clip] {
        store.project.allTextClips
            .map(\.clip)
            .filter { clip in
                guard let filter = templateFilter else { return true }
                return clip.content.textInstance?.templateID == filter
            }
            .sorted { $0.start < $1.start }
    }

    /// 絞り込んだ結果が 1 種類のテンプレートに揃っているときだけ props を列に出す。
    private var activeTemplate: TextTemplate? {
        let ids = Set(rows.compactMap { $0.content.textInstance?.templateID })
        guard ids.count == 1, let id = ids.first else { return nil }
        return store.project.template(id)
    }

    private var stringProps: [PropDef] {
        activeTemplate?.props.filter { $0.type == .string && $0.showInBulkEditor } ?? []
    }

    private var otherProps: [PropDef] {
        activeTemplate?.props.filter { $0.type != .string && $0.showInBulkEditor } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                empty
            } else {
                table
            }
        }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(spacing: 10) {
            BottomTabPicker(selection: $bottomTab)

            Divider().frame(height: 16)

            Picker("", selection: $templateFilter) {
                Text("すべて").tag(UUID?.none)
                ForEach(store.project.textTemplates) { t in
                    Text(LName(t.name)).tag(UUID?.some(t.id))
                }
            }
            .labelsHidden()
            .fixedSize()

            Menu {
                ForEach(store.project.textTemplates) { template in
                    Button(LName(template.name)) { add(template) }
                }
            } label: {
                Label("追加", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("再生ヘッドの位置にテキストを足す")

            if SubtitleGeneration.isAvailable {
                generateControl
            }

            Spacer()

            if checked.isEmpty {
                Text("\(rows.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                bulkControls
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// 音声からの自動生成。進行中は進み具合と中止に差し替わる。
    @ViewBuilder
    private var generateControl: some View {
        if let progress = store.subtitleProgress {
            // 割合が取れる段階だけ帯にする。取れないあいだにゼロの帯を出すと、
            // 止まっているように見える。
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            Text(progress.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("中止") { store.cancelSubtitleGeneration() }
                .font(.caption)
        } else {
            Menu {
                Picker("言語", selection: $transcriptionLocale) {
                    Text("日本語").tag(Locale(identifier: "ja-JP"))
                    Text("English").tag(Locale(identifier: "en-US"))
                }
                Divider()
                Section("このテンプレートで作る") {
                    ForEach(store.project.textTemplates) { template in
                        Button(LName(template.name)) { generate(with: template) }
                    }
                }
            } label: {
                Label("自動生成", systemImage: "waveform.badge.mic")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.contentEnd <= 0)
            .help("タイムラインの音声を端末内で書き起こして字幕にする")
        }
    }

    private func generate(with template: TextTemplate) {
        let locale = transcriptionLocale
        Task { @MainActor in
            await store.generateSubtitles(locale: locale, templateID: template.id)
        }
    }

    /// チェックした行へまとめて適用する操作。
    private var bulkControls: some View {
        HStack(spacing: 10) {
            Text("\(checked.count) 件を選択")
                .font(.caption)
                .foregroundStyle(.orange)

            ForEach(otherProps) { def in
                if def.type == .color {
                    ColorPicker(LName(def.label), selection: Binding(
                        get: { Color(commonColor(def) ?? .white) },
                        set: { store.setTextProp(def.key, to: .color(RGBAColor($0)), clipIDs: checked) }
                    ), supportsOpacity: true)
                    .labelsHidden()
                    .help(LName(def.label))
                }
            }

            Menu("フェード") {
                Button("0.2 秒") { applyFade(0.2) }
                Button("0.5 秒") { applyFade(0.5) }
                Button("なし") { applyFade(0) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("タイムラインで選択") { store.selectedClipIDs = checked }
            Button("削除", role: .destructive) {
                store.selectedClipIDs = checked
                store.deleteSelection()
                checked = []
            }
            Button {
                checked = []
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .help("選択を解除")
        }
        .font(.caption)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("テキストクリップがありません")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("上の「追加」か、タイムラインを右クリックして置けます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - 表

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                columnHeader
                ForEach(rows) { clip in
                    row(clip)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !rows.isEmpty && checked.count == rows.count },
                set: { on in checked = on ? Set(rows.map(\.id)) : [] }
            ))
            .labelsHidden()
            .frame(width: 20)

            Text("開始").frame(width: 72, alignment: .leading)
            if stringProps.isEmpty {
                Text("内容（テンプレートごとの主要項目）")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(stringProps) { def in
                    Text(LName(def.label)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("尺 (秒)").frame(width: 50, alignment: .trailing)
            Color.clear.frame(width: 26)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { checked.contains(clip.id) },
                set: { on in
                    if on { checked.insert(clip.id) } else { checked.remove(clip.id) }
                }
            ))
            .labelsHidden()
            .frame(width: 20)

            Button(Format.timecode(clip.start, fps: store.project.canvas.fps)) {
                store.seek(to: clip.start)
                store.selectedClipIDs = [clip.id]
            }
            .buttonStyle(.link)
            .font(.system(.caption, design: .monospaced))
            .frame(width: 72, alignment: .leading)

            if stringProps.isEmpty {
                // テンプレートが混在しているときは、行ごとに自前の主要項目を編集する。
                if let def = primaryProp(clip) {
                    TextPropField(store: store, clip: clip, def: def)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(summary(clip))
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(stringProps) { def in
                    TextPropField(store: store, clip: clip, def: def)
                        .frame(maxWidth: .infinity)
                }
            }

            Text(Format.seconds(clip.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)

            Button {
                store.selectedClipIDs = [clip.id]
                store.deleteSelection()
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(width: 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(store.selectedClipIDs.contains(clip.id)
                    ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedClipIDs = [clip.id] }
    }

    /// 行ごとの主要なテキスト項目。テンプレートが混ざっていても打ち替えられるようにする。
    private func primaryProp(_ clip: Clip) -> PropDef? {
        guard let inst = clip.content.textInstance,
              let template = store.project.template(inst.templateID) else { return nil }
        return template.props.first { $0.type == .string && $0.showInBulkEditor }
    }

    private func summary(_ clip: Clip) -> String {
        guard let inst = clip.content.textInstance,
              let template = store.project.template(inst.templateID) else { return "" }
        let parts = template.props
            .filter { $0.type == .string }
            .compactMap { inst.value($0.key, in: template)?.stringValue }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? LName(template.name) : parts.joined(separator: " / ")
    }

    // MARK: - 操作

    private func add(_ template: TextTemplate) {
        let track = store.selectedTrackID.flatMap { id in
            store.project.tracks.first { $0.id == id && $0.kind == .video }
        } ?? store.project.tracks.last { $0.kind == .video }
        guard let track else { return }
        store.addTextClip(templateID: template.id, trackID: track.id, at: store.currentTime)
    }

    private func commonColor(_ def: PropDef) -> RGBAColor? {
        guard let template = activeTemplate else { return nil }
        let values = rows.filter { checked.contains($0.id) }
            .compactMap { $0.content.textInstance?.value(def.key, in: template)?.colorValue }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func applyFade(_ seconds: Double) {
        let ids = checked
        store.edit { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    let limit = p.tracks[ti].clips[ci].duration / 2
                    p.tracks[ti].clips[ci].fade = Fade(inDuration: min(seconds, limit),
                                                       outDuration: min(seconds, limit))
                }
            }
        }
    }
}

/// 表の中のテキスト入力。入力中は undo をまとめる。
private struct TextPropField: View {
    @Bindable var store: EditorStore
    let clip: Clip
    let def: PropDef

    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onAppear { reload() }
            .onChange(of: text) { _, new in
                guard loaded else { return }
                store.setTextProp(def.key, to: .string(new), clipIDs: [clip.id],
                                  coalesceKey: "table:\(clip.id):\(def.key)")
            }
            .onChange(of: clip.id) { _, _ in reload() }
    }

    private func reload() {
        loaded = false
        if let inst = clip.content.textInstance,
           let template = store.project.template(inst.templateID) {
            text = inst.value(def.key, in: template)?.stringValue ?? ""
        }
        loaded = true
    }
}
