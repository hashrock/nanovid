import SwiftUI

/// テキストレイヤーの一括編集。字幕の打ち直しや、色・サイズのまとめ替えを想定。
struct BulkTextEditorView: View {
    @Bindable var store: EditorStore
    @Environment(\.dismiss) private var dismiss

    @State private var templateFilter: UUID?
    @State private var checked: Set<UUID> = []

    private var rows: [Clip] {
        store.project.allTextClips
            .map(\.clip)
            .filter { clip in
                guard let filter = templateFilter else { return true }
                return clip.content.textInstance?.templateID == filter
            }
            .sorted { $0.start < $1.start }
    }

    /// 現在の絞り込みで共通して編集できるテンプレート（1 種類のときだけ props を出す）。
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if rows.isEmpty {
                ContentUnavailableView("テキストクリップがありません", systemImage: "textformat")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 520)
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: 12) {
            Text("テキスト一括編集").font(.title3.bold())

            Picker("", selection: $templateFilter) {
                Text("すべてのテンプレート").tag(UUID?.none)
                ForEach(store.project.textTemplates) { t in
                    Text(t.name).tag(UUID?.some(t.id))
                }
            }
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text("\(rows.count) 件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
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
                Text("内容").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(stringProps) { def in
                    Text(def.label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("尺").frame(width: 54, alignment: .trailing)
            Color.clear.frame(width: 28)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
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
                Text(summary(clip))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(stringProps) { def in
                    BulkTextField(store: store, clip: clip, def: def)
                        .frame(maxWidth: .infinity)
                }
            }

            Text(Format.duration(clip.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)

            Button {
                store.selectedClipIDs = [clip.id]
                store.deleteSelection()
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(store.selectedClipIDs.contains(clip.id)
                    ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func summary(_ clip: Clip) -> String {
        guard let inst = clip.content.textInstance,
              let template = store.project.template(inst.templateID) else { return "" }
        let parts = template.props
            .filter { $0.type == .string }
            .compactMap { inst.value($0.key, in: template)?.stringValue }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? template.name : parts.joined(separator: " / ")
    }

    // MARK: - フッタ（選択行へのまとめ適用）

    private var footer: some View {
        HStack(spacing: 12) {
            if checked.isEmpty {
                Text("行を選ぶと、色やフェードをまとめて変更できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(checked.count) 件を選択中").font(.caption)

                ForEach(otherProps) { def in
                    bulkPropControl(def)
                }

                Menu("フェード") {
                    Button("0.2 秒") { applyFade(0.2) }
                    Button("0.5 秒") { applyFade(0.5) }
                    Button("なし") { applyFade(0) }
                }
                .fixedSize()

                Button("タイムラインで選択") {
                    store.selectedClipIDs = checked
                }
            }

            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private func bulkPropControl(_ def: PropDef) -> some View {
        switch def.type {
        case .color:
            ColorPicker(def.label, selection: Binding(
                get: { Color(commonColor(def) ?? .white) },
                set: { store.setTextProp(def.key, to: .color(RGBAColor($0)), clipIDs: checked) }
            ), supportsOpacity: true)
            .labelsHidden()
            .help(def.label)
        case .bool:
            Toggle(def.label, isOn: Binding(
                get: { false },
                set: { store.setTextProp(def.key, to: .bool($0), clipIDs: checked) }
            ))
            .toggleStyle(.checkbox)
        default:
            EmptyView()
        }
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

/// 行内のテキスト入力。入力中は undo をまとめ、確定でコミットする。
private struct BulkTextField: View {
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
                                  coalesceKey: "bulk:\(clip.id):\(def.key)")
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
