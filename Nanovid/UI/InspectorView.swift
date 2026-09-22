import SwiftUI

struct InspectorView: View {
    @Bindable var store: EditorStore

    private var selectedClips: [Clip] {
        store.project.tracks.flatMap { $0.clips }.filter { store.selectedClipIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selectedClips.isEmpty {
                    canvasSection
                } else {
                    clipSection(selectedClips)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - キャンバス設定

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("プロジェクト")

            LabeledContent("解像度") {
                Menu(currentPresetName) {
                    ForEach(CanvasPresetOption.all) { option in
                        Button(option.name) {
                            store.setCanvas(width: Int(option.size.width),
                                            height: Int(option.size.height),
                                            fps: store.project.canvas.fps)
                        }
                    }
                }
                .fixedSize()
            }

            LabeledContent("フレームレート") {
                Picker("", selection: Binding(
                    get: { store.project.canvas.fps },
                    set: { fps in
                        store.setCanvas(width: store.project.canvas.width,
                                        height: store.project.canvas.height, fps: fps)
                    }
                )) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            LabeledContent("背景色") {
                ColorPicker("", selection: Binding(
                    get: { Color(store.project.canvas.backgroundColor) },
                    set: { newColor in store.edit { $0.canvas.backgroundColor = RGBAColor(newColor) } }
                ), supportsOpacity: false)
                .labelsHidden()
            }

            Text("\(store.project.canvas.width) × \(store.project.canvas.height) / \(store.project.canvas.fps)fps")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            outputRangeBlock

            Divider()
            Text("クリップを選択すると、ここで詳細を編集できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 書き出す範囲。タイムラインのマーカーと同じ値を数字で触れるようにする。
    private var outputRangeBlock: some View {
        let fps = store.project.canvas.fps
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("動画の範囲").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.project.hasExplicitOutputRange {
                    Button("自動に戻す") { store.resetOutputRange() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }

            TimecodeRow(label: "開始", seconds: store.outputStart, fps: fps) {
                store.setOutputStart($0)
            }
            TimecodeRow(label: "長さ", seconds: store.duration, fps: fps) {
                store.setOutputDuration($0)
            }
            TimecodeRow(label: "終了", seconds: store.outputEnd, fps: fps) {
                store.setOutputEnd($0)
            }

            Text(store.project.hasExplicitOutputRange
                 ? "この範囲だけを書き出します。"
                 : "クリップの終わりに合わせています。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var currentPresetName: String {
        let size = store.project.canvas.size
        return CanvasPresetOption.all.first { $0.size == size }?.name
            ?? "\(store.project.canvas.width)×\(store.project.canvas.height)"
    }

    // MARK: - クリップ設定

    @ViewBuilder
    private func clipSection(_ clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1 個のときは数を出さない。日本語には CLDR の単数形が無いので、
            // これはカタログの複数形では書けず、ここで分ける（英語側は
            // %lld 個のクリップ に one/other を持たせてある）。
            SectionHeader(clips.count == 1 ? "クリップ" : "\(clips.count) 個のクリップ")

            timingBlock(clips)
            Divider()
            fadeBlock(clips)

            if clips.contains(where: { $0.content.textInstance == nil }) {
                Divider()
                transformBlock(clips)
            }

            Divider()
            volumeBlock(clips)

            if let shared = sharedTemplate(clips) {
                Divider()
                textPropsBlock(template: shared, clips: clips)
            } else if clips.allSatisfy({ $0.content.textInstance != nil }) {
                Divider()
                Text("種類の違うテンプレートが混在しています。同じテンプレートのクリップだけを選ぶと props を一括編集できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timingBlock(_ clips: [Clip]) -> some View {
        let fps = store.project.canvas.fps
        return VStack(alignment: .leading, spacing: 6) {
            if let single = clips.count == 1 ? clips.first : nil {
                LabeledContent("開始") {
                    Text(Format.timecode(single.start, fps: fps))
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("長さ") {
                    Text(Format.timecode(single.duration, fps: fps))
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                let total = clips.map(\.duration).reduce(0, +)
                LabeledContent("合計の長さ") {
                    Text(Format.timecode(total, fps: fps))
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private func fadeBlock(_ clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("フェード").font(.caption).foregroundStyle(.secondary)
            NumberRow(label: "イン", value: mixed(clips) { $0.fade.inDuration },
                      range: 0...5, unit: L("秒")) { v in
                store.updateSelectedClips { $0.fade.inDuration = min(v, $0.duration / 2) }
            }
            NumberRow(label: "アウト", value: mixed(clips) { $0.fade.outDuration },
                      range: 0...5, unit: L("秒")) { v in
                store.updateSelectedClips { $0.fade.outDuration = min(v, $0.duration / 2) }
            }
        }
    }

    private func transformBlock(_ clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配置").font(.caption).foregroundStyle(.secondary)
            NumberRow(label: "拡大", value: mixed(clips) { $0.transform.scale },
                      range: 0.05...8, unit: "×") { v in
                store.updateSelectedClips { $0.transform.scale = v }
            }
            NumberRow(label: "位置 X", value: mixed(clips) { $0.transform.position.x },
                      range: -2...2, unit: "") { v in
                store.updateSelectedClips { $0.transform.position.x = v }
            }
            NumberRow(label: "位置 Y", value: mixed(clips) { $0.transform.position.y },
                      range: -2...2, unit: "") { v in
                store.updateSelectedClips { $0.transform.position.y = v }
            }
            NumberRow(label: "不透明度", value: mixed(clips) { $0.opacity },
                      range: 0...1, unit: "") { v in
                store.updateSelectedClips { $0.opacity = v }
            }
        }
    }

    private func volumeBlock(_ clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音量").font(.caption).foregroundStyle(.secondary)
            NumberRow(label: "ボリューム", value: mixed(clips) { $0.volume },
                      range: 0...2, unit: "×") { v in
                store.updateSelectedClips { $0.volume = v }
            }
        }
    }

    // MARK: - テキスト props

    private func sharedTemplate(_ clips: [Clip]) -> TextTemplate? {
        let ids = Set(clips.compactMap { $0.content.textInstance?.templateID })
        guard ids.count == 1, let id = ids.first else { return nil }
        return store.project.template(id)
    }

    private func textPropsBlock(template: TextTemplate, clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("テキスト（\(LName(template.name))）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if clips.count > 1 {
                    Text("\(clips.count) 件に適用")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(template.props) { def in
                PropEditor(
                    def: def,
                    values: clips.compactMap { $0.content.textInstance?.value(def.key, in: template) },
                    isOverridden: clips.contains { $0.content.textInstance?.props[def.key] != nil },
                    onChange: { store.setTextProp(def.key, to: $0) },
                    onReset: { store.resetTextProp(def.key) }
                )
            }

            if store.project.textTemplates.count > 1 {
                Menu("テンプレートを変更") {
                    ForEach(store.project.textTemplates) { t in
                        Button(LName(t.name)) { store.retemplate(clipIDs: store.selectedClipIDs, to: t.id) }
                    }
                }
                .fixedSize()
            }
        }
    }

    /// 選択した全クリップで値が一致すればその値、違えば nil。
    private func mixed(_ clips: [Clip], _ keyPath: (Clip) -> Double) -> Double? {
        let values = clips.map(keyPath)
        guard let first = values.first else { return nil }
        return values.allSatisfy { abs($0 - first) < 1e-9 } ? first : nil
    }
}

// MARK: - 部品

struct SectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        Text(title).font(.headline)
    }
}

/// 値が混在しているときは空欄になる数値入力。
struct NumberRow: View {
    let label: LocalizedStringKey
    let value: Double?
    let range: ClosedRange<Double>
    let unit: String
    let onChange: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 66, alignment: .leading)
            Slider(value: Binding(
                get: { value ?? range.lowerBound },
                set: { onChange($0) }
            ), in: range)
            TextField("—", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 58)
                .focused($focused)
                .onSubmit { commit() }
            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: value) { _, new in
            if !focused { text = new.map { String(format: "%.3g", $0) } ?? "" }
        }
        .onAppear { text = value.map { String(format: "%.3g", $0) } ?? "" }
    }

    private func commit() {
        guard let v = Double(text) else { return }
        onChange(min(max(v, range.lowerBound), range.upperBound))
    }
}

/// PropType に応じた入力欄。複数選択で値が混在している場合はその旨を出す。
struct PropEditor: View {
    let def: PropDef
    let values: [PropValue]
    let isOverridden: Bool
    let onChange: (PropValue) -> Void
    let onReset: () -> Void

    @State private var draft: String = ""

    private var uniform: PropValue? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private var isMixed: Bool { uniform == nil && values.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(LName(def.label)).font(.caption)
                if isOverridden {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help("テンプレートの既定値に戻す")
                }
                Spacer()
                if isMixed {
                    Text("複数の値").font(.caption2).foregroundStyle(.orange)
                }
            }
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch def.type {
        case .string:
            TextField(isMixed ? "複数の値" : "", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { onChange(.string(draft)) }
                .onChange(of: draft) { _, new in onChange(.string(new)) }
                .onAppear { draft = uniform?.stringValue ?? "" }
                .onChange(of: uniform) { _, new in
                    let s = new?.stringValue ?? ""
                    if s != draft { draft = s }
                }

        case .color:
            ColorPicker("", selection: Binding(
                get: { Color(uniform?.colorValue ?? .white) },
                set: { onChange(.color(RGBAColor($0))) }
            ), supportsOpacity: true)
            .labelsHidden()

        case .number:
            NumberRow(label: "", value: uniform?.numberValue, range: -1000...1000, unit: "") {
                onChange(.number($0))
            }

        case .bool:
            Toggle("", isOn: Binding(
                get: { uniform?.boolValue ?? false },
                set: { onChange(.bool($0)) }
            ))
            .labelsHidden()

        case .point:
            HStack {
                NumberRow(label: "X", value: uniform?.pointValue.map { Double($0.x) },
                          range: -2...2, unit: "") { v in
                    var p = uniform?.pointValue ?? .zero
                    p.x = v
                    onChange(.point(p))
                }
                NumberRow(label: "Y", value: uniform?.pointValue.map { Double($0.y) },
                          range: -2...2, unit: "") { v in
                    var p = uniform?.pointValue ?? .zero
                    p.y = v
                    onChange(.point(p))
                }
            }
        }
    }
}

/// UI で選べる解像度プリセット。
struct CanvasPresetOption: Identifiable {
    var id: String { name }
    let name: String
    let size: CGSize

    static let all: [CanvasPresetOption] = CanvasPreset.all.map {
        CanvasPresetOption(name: $0.name, size: $0.size)
    }
}

/// タイムコードで時刻を入れる行。
///
/// 確定するまで外の値で上書きしない。打っている途中に
/// 正規化された文字列が降ってくると、カーソルが飛んで打てなくなる。
struct TimecodeRow: View {
    let label: LocalizedStringKey
    let seconds: Double
    let fps: Int
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 66, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 90)
                .focused($focused)
                // 確定はフォーカスが外れたときの一本道にする。
                .onSubmit { focused = false }
            Spacer(minLength: 0)
        }
        .onChange(of: seconds) { _, new in if !focused { text = Format.timecode(new, fps: fps) } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onAppear { text = Format.timecode(seconds, fps: fps) }
    }

    private func commit() {
        if let parsed = Format.parseTimecode(text, fps: fps) {
            onCommit(parsed)
        }
        // 読めなかった入力は捨てて表示を戻す。受理された場合も、
        // 丸めたあとの値が onChange(of: seconds) で入ってくる。
        text = Format.timecode(seconds, fps: fps)
    }
}
