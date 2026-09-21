import SwiftUI

/// テキストテンプレートのレイアウトを GUI で組む。
/// ここで決めた配置を、タイムライン上の各インスタンスが props だけ差し替えて使い回す。
struct TemplateEditorView: View {
    @Bindable var store: EditorStore
    let templateID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TextTemplate?
    @State private var selectedNodeID: UUID?
    /// プレビュー確認用の一時的な props（保存はされない）。
    @State private var previewProps: [String: PropValue] = [:]
    /// props の表の高さ。下段に置いたので上下に調整できる。
    @State private var propsHeight: CGFloat = 175

    var body: some View {
        Group {
            if let draft {
                content(draft)
            } else {
                ProgressView()
            }
        }
        // シートを広げられるようにする。列の幅もユーザーが調整できる。
        // シートは idealWidth ではなく minWidth の幅で開く。プレビューが
        // まともな大きさになる幅を最小として置いておく。
        .frame(minWidth: 1100, idealWidth: 1280, maxWidth: .infinity,
               minHeight: 660, idealHeight: 900, maxHeight: .infinity)
        .onAppear {
            draft = store.project.template(templateID)
            selectedNodeID = draft?.nodes.last?.id
            previewProps = draft?.defaultProps ?? [:]
        }
    }

    private func content(_ template: TextTemplate) -> some View {
        GeometryReader { geo in
            // props の表は横に長い。中央の列に入れるとプレビューの幅を押しのけて
            // はみ出すので、下段に回して横幅いっぱいを使わせる。
            VStack(spacing: 0) {
                header(template)
                Divider()
                HSplitView {
                    // 上限を絞る。HSplitView は空きを分け合うので、上限が緩いと
                    // 脇の列が広がってプレビューが痩せる。
                    nodeColumn(template)
                        .frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
                    TemplatePreview(template: template,
                                    props: previewProps,
                                    canvas: store.project.canvas)
                        .frame(minWidth: 320)
                    inspectorColumn(template)
                        .frame(minWidth: 280, idealWidth: 310, maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PaneDivider.Horizontal(
                    bottomHeight: $propsHeight,
                    range: 120...max(120, geo.size.height - 320))
                propsColumn(template)
                    .frame(height: resolvedPropsHeight(in: geo.size.height))
                Divider()
                footer
            }
        }
    }

    /// 窓が小さいときでも上段が潰れないように収める。
    private func resolvedPropsHeight(in total: CGFloat) -> CGFloat {
        min(max(propsHeight, 120), max(120, total - 320))
    }

    // MARK: - ヘッダ

    private func header(_ template: TextTemplate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat").foregroundStyle(.secondary)
            TextField("テンプレート名", text: binding(\.name, fallback: template.name))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Spacer()
            Text("使用中: \(store.project.textClips(usingTemplate: templateID).count) クリップ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - ノード一覧

    private func nodeColumn(_ template: TextTemplate) -> some View {
        VStack(spacing: 0) {
            List(selection: $selectedNodeID) {
                Section("レイヤー（下が前面）") {
                    ForEach(template.nodes) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.isHidden ? "eye.slash" : iconFor(node))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(node.name).font(.caption)
                            Spacer()
                        }
                        .tag(node.id)
                    }
                    .onMove { indices, destination in
                        draft?.nodes.move(fromOffsets: indices, toOffset: destination)
                    }
                    .onDelete { offsets in
                        draft?.nodes.remove(atOffsets: offsets)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 6) {
                Button {
                    addNode(.text(TextNodeSpec()))
                } label: { Label("テキスト", systemImage: "plus") }
                Button {
                    addNode(.rect(RectNodeSpec()))
                } label: { Label("図形", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(8)
        }
    }

    private func iconFor(_ node: TemplateNode) -> String {
        if case .text = node.kind { return "textformat" }
        return "rectangle"
    }

    private func addNode(_ kind: NodeKind) {
        var node = TemplateNode(name: {
            if case .text = kind { return "テキスト" }
            return "図形"
        }(), kind: kind)
        node.frame = RelFrame(x: 0.5, y: 0.5, width: 0.7, height: 0.12, anchor: .center)
        draft?.nodes.append(node)
        selectedNodeID = node.id
    }

    // MARK: - props 定義

    private func propsColumn(_ template: TextTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("props（インスタンス側で上書きできる項目）")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var def = PropDef(key: uniqueKey(template), label: "新しい項目",
                                      type: .string, defaultValue: .string(""))
                    def.id = UUID()
                    draft?.props.append(def)
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(template.props) { def in
                        propDefRow(def)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    private func propDefRow(_ def: PropDef) -> some View {
        HStack(spacing: 6) {
            TextField("key", text: bindingProp(def.id, \.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 70, idealWidth: 96, maxWidth: 140)
            TextField("表示名", text: bindingProp(def.id, \.label))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(minWidth: 80, idealWidth: 120, maxWidth: 180)
            Picker("", selection: Binding(
                get: { def.type },
                set: { newType in
                    updateProp(def.id) {
                        $0.type = newType
                        $0.defaultValue = newType.defaultValue
                    }
                    previewProps[def.key] = newType.defaultValue
                }
            )) {
                ForEach(PropType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 92)

            defaultValueEditor(def)

            Spacer(minLength: 0)
            Button {
                draft?.props.removeAll { $0.id == def.id }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func defaultValueEditor(_ def: PropDef) -> some View {
        switch def.type {
        case .string:
            TextField("既定値", text: Binding(
                get: { def.defaultValue.stringValue ?? "" },
                set: { v in
                    updateProp(def.id) { $0.defaultValue = .string(v) }
                    previewProps[def.key] = .string(v)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(minWidth: 120, idealWidth: 220, maxWidth: 360)
        case .color:
            ColorPicker("", selection: Binding(
                get: { Color(def.defaultValue.colorValue ?? .white) },
                set: { v in
                    let c = RGBAColor(v)
                    updateProp(def.id) { $0.defaultValue = .color(c) }
                    previewProps[def.key] = .color(c)
                }
            ), supportsOpacity: true)
            .labelsHidden()
        case .number:
            TextField("0", value: Binding(
                get: { def.defaultValue.numberValue ?? 0 },
                set: { v in
                    updateProp(def.id) { $0.defaultValue = .number(v) }
                    previewProps[def.key] = .number(v)
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(width: 70)
        case .bool:
            Toggle("", isOn: Binding(
                get: { def.defaultValue.boolValue ?? false },
                set: { v in
                    updateProp(def.id) { $0.defaultValue = .bool(v) }
                    previewProps[def.key] = .bool(v)
                }
            ))
            .labelsHidden()
        case .point:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func uniqueKey(_ template: TextTemplate) -> String {
        var i = 1
        while template.props.contains(where: { $0.key == "prop\(i)" }) { i += 1 }
        return "prop\(i)"
    }

    // MARK: - ノードのインスペクタ

    @ViewBuilder
    private func inspectorColumn(_ template: TextTemplate) -> some View {
        ScrollView {
            if let nodeID = selectedNodeID,
               let index = template.nodes.firstIndex(where: { $0.id == nodeID }) {
                NodeInspector(
                    node: Binding(
                        get: { draft?.nodes[index] ?? template.nodes[index] },
                        set: { draft?.nodes[index] = $0 }
                    ),
                    template: template
                )
                .padding(12)
            } else {
                Text("レイヤーを選んでください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
    }

    // MARK: - フッタ

    private var footer: some View {
        HStack {
            Button("複製して新規に") {
                guard var copy = draft else { return }
                copy.id = UUID()
                copy.name += " のコピー"
                copy.nodes = copy.nodes.map { var n = $0; n.id = UUID(); return n }
                store.upsertTemplate(copy)
                dismiss()
            }
            Spacer()
            Button("キャンセル") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") {
                if let draft {
                    store.upsertTemplate(draft)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - バインディング補助

    private func binding<T>(_ keyPath: WritableKeyPath<TextTemplate, T>,
                            fallback: T) -> Binding<T> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func bindingProp(_ id: UUID, _ keyPath: WritableKeyPath<PropDef, String>) -> Binding<String> {
        Binding(
            get: { draft?.props.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { v in updateProp(id) { $0[keyPath: keyPath] = v } }
        )
    }

    private func updateProp(_ id: UUID, _ body: (inout PropDef) -> Void) {
        guard let i = draft?.props.firstIndex(where: { $0.id == id }) else { return }
        body(&draft!.props[i])
    }
}

// MARK: - プレビュー

/// テンプレートを実キャンバスサイズでラスタライズして、縮小表示する。
struct TemplatePreview: View {
    let template: TextTemplate
    let props: [String: PropValue]
    let canvas: CanvasSpec

    var body: some View {
        GeometryReader { geo in
            let box = fit(in: geo.size)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(canvas.backgroundColor))
                    if let raster = TextRasterizer.shared.rasterize(
                        template: template, props: props, canvas: canvas.size
                    ) {
                        let scale = box.width / canvas.size.width
                        Image(decorative: raster.image, scale: 1)
                            .resizable()
                            .frame(width: raster.rect.width * scale,
                                   height: raster.rect.height * scale)
                            .offset(x: raster.rect.minX * scale, y: raster.rect.minY * scale)
                    }
                }
                .frame(width: box.width, height: box.height)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.1)))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func fit(in size: CGSize) -> CGSize {
        let padding: Double = 12
        let w = max(1, size.width - padding * 2)
        let h = max(1, size.height - padding * 2)
        let aspect = canvas.aspectRatio
        return w / h > aspect ? CGSize(width: h * aspect, height: h)
                              : CGSize(width: w, height: w / aspect)
    }
}

// MARK: - ノードのプロパティ編集

private struct NodeInspector: View {
    @Binding var node: TemplateNode
    let template: TextTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("レイヤー名", text: $node.name)
                .textFieldStyle(.roundedBorder)

            Toggle("非表示", isOn: $node.isHidden)
                .toggleStyle(.checkbox)
                .font(.caption)

            Divider()
            frameSection

            Divider()
            switch node.kind {
            case .text(let spec):
                textSection(spec)
            case .rect(let spec):
                rectSection(spec)
            }
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配置（キャンバス比）").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("基準", selection: $node.frame.anchor) {
                ForEach(Anchor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .font(.caption)
            ratioField("X", $node.frame.x)
            ratioField("Y", $node.frame.y)
            ratioField("幅", $node.frame.width)
            ratioField("高さ", $node.frame.height)
            ratioField("不透明度", $node.opacity)
        }
    }

    private func ratioField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: -0.5...1.5)
            TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 54)
        }
    }

    // MARK: テキスト

    private func textSection(_ spec: TextNodeSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("テキスト").font(.caption.bold()).foregroundStyle(.secondary)

            ValueRefEditor(label: "内容", type: .string, template: template,
                           value: Binding(
                            get: { spec.text },
                            set: { update { $0.text = $1 } (spec, $0) }
                           ))

            ValueRefEditor(label: "文字色", type: .color, template: template,
                           value: Binding(
                            get: { spec.color },
                            set: { update { $0.color = $1 } (spec, $0) }
                           ))

            HStack(spacing: 6) {
                Text("フォント").font(.caption).frame(width: 52, alignment: .leading)
                TextField("システム", text: Binding(
                    get: { spec.font.name },
                    set: { v in update { $0.font.name = $1 } (spec, v) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            numberRow("サイズ", spec.font.relativeSize, range: 0.01...0.4) { v in
                update { $0.font.relativeSize = $1 } (spec, v)
            }
            numberRow("太さ", spec.font.weight, range: -0.8...0.9) { v in
                update { $0.font.weight = $1 } (spec, v)
            }
            numberRow("行送り", spec.lineSpacing, range: 0...1) { v in
                update { $0.lineSpacing = $1 } (spec, v)
            }

            Picker("整列", selection: Binding(
                get: { spec.align },
                set: { v in update { $0.align = $1 } (spec, v) }
            )) {
                ForEach(TextAlign.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .font(.caption)

            numberRow("縁取り", spec.strokeWidth, range: 0...0.25) { v in
                update { $0.strokeWidth = $1 } (spec, v)
            }
            if spec.strokeWidth > 0 {
                ValueRefEditor(label: "縁の色", type: .color, template: template,
                               value: Binding(
                                get: { spec.strokeColor },
                                set: { v in update { $0.strokeColor = $1 } (spec, v) }
                               ))
            }
            numberRow("影のぼかし", spec.shadowRadius, range: 0...0.03) { v in
                update { $0.shadowRadius = $1 } (spec, v)
            }
            numberRow("影のずれ", spec.shadowOffset.y, range: -0.02...0.02) { v in
                update { $0.shadowOffset.y = $1 } (spec, v)
            }
            if spec.shadowRadius > 0 {
                ValueRefEditor(label: "影の色", type: .color, template: template,
                               value: Binding(
                                get: { spec.shadowColor },
                                set: { v in update { $0.shadowColor = $1 } (spec, v) }
                               ))
            }
        }
    }

    /// TextNodeSpec の一部だけを差し替えて node に書き戻す。
    private func update<V>(_ apply: @escaping (inout TextNodeSpec, V) -> Void)
        -> (TextNodeSpec, V) -> Void {
        { spec, value in
            var copy = spec
            apply(&copy, value)
            node.kind = .text(copy)
        }
    }

    // MARK: 図形

    private func rectSection(_ spec: RectNodeSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("図形").font(.caption.bold()).foregroundStyle(.secondary)

            ValueRefEditor(label: "塗り", type: .color, template: template,
                           value: Binding(
                            get: { spec.fill },
                            set: { v in updateRect { $0.fill = $1 } (spec, v) }
                           ))

            numberRow("角丸", spec.cornerRadius, range: 0...0.2) { v in
                updateRect { $0.cornerRadius = $1 } (spec, v)
            }

            Picker("文字幅に追従", selection: Binding(
                get: { spec.fitToNodeID },
                set: { v in updateRect { $0.fitToNodeID = $1 } (spec, v) }
            )) {
                Text("しない").tag(UUID?.none)
                ForEach(textNodes) { n in
                    Text(n.name).tag(UUID?.some(n.id))
                }
            }
            .font(.caption)

            if spec.fitToNodeID != nil {
                numberRow("余白 X", spec.padding.x, range: 0...0.2) { v in
                    updateRect { $0.padding.x = $1 } (spec, v)
                }
                numberRow("余白 Y", spec.padding.y, range: 0...0.2) { v in
                    updateRect { $0.padding.y = $1 } (spec, v)
                }
            }
        }
    }

    private var textNodes: [TemplateNode] {
        template.nodes.filter { if case .text = $0.kind { return true }; return false }
    }

    private func updateRect<V>(_ apply: @escaping (inout RectNodeSpec, V) -> Void)
        -> (RectNodeSpec, V) -> Void {
        { spec, value in
            var copy = spec
            apply(&copy, value)
            node.kind = .rect(copy)
        }
    }

    // MARK: 部品

    private func numberRow(_ label: String, _ value: Double,
                           range: ClosedRange<Double>,
                           onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            Text(String(format: "%.3g", value))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// 「固定値」と「props へのバインド」を切り替える入力欄。
private struct ValueRefEditor: View {
    let label: String
    let type: PropType
    let template: TextTemplate
    @Binding var value: ValueRef

    private var candidates: [PropDef] { template.props.filter { $0.type == type } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.caption).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(
                    get: { value.boundKey ?? "" },
                    set: { key in
                        value = key.isEmpty ? .literal(type.defaultValue) : .prop(key)
                    }
                )) {
                    Text("固定値").tag("")
                    ForEach(candidates) { def in
                        Text("props.\(def.key)").tag(def.key)
                    }
                }
                .labelsHidden()
            }
            if case .literal(let v) = value {
                literalEditor(v)
                    .padding(.leading, 58)
            }
        }
    }

    @ViewBuilder
    private func literalEditor(_ current: PropValue) -> some View {
        switch type {
        case .string:
            TextField("", text: Binding(
                get: { current.stringValue ?? "" },
                set: { value = .literal(.string($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        case .color:
            ColorPicker("", selection: Binding(
                get: { Color(current.colorValue ?? .white) },
                set: { value = .literal(.color(RGBAColor($0))) }
            ), supportsOpacity: true)
            .labelsHidden()
        default:
            EmptyView()
        }
    }
}
