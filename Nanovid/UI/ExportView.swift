import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Bindable var store: EditorStore
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var outputURL: URL?
    @State private var progress: Double = 0
    @State private var isExporting = false
    @State private var errorText: String?
    @State private var finishedURL: URL?
    @State private var exporter: Exporter?

    private var canvas: CanvasSpec { store.project.canvas }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("書き出し").font(.title3.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("解像度").foregroundStyle(.secondary)
                    Text("\(canvas.width) × \(canvas.height) · \(canvas.fps)fps")
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("長さ").foregroundStyle(.secondary)
                    Text(Format.timecode(store.duration, fps: canvas.fps))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("コーデック").foregroundStyle(.secondary)
                    Picker("", selection: $settings.codec) {
                        ForEach(ExportSettings.Codec.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("画質").foregroundStyle(.secondary)
                    Picker("", selection: $settings.quality) {
                        ForEach(ExportSettings.Quality.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                GridRow {
                    Text("目安").foregroundStyle(.secondary)
                    Text(estimate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("出力先").foregroundStyle(.secondary)
                    HStack {
                        Text(outputURL?.lastPathComponent ?? "未選択")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("選択…") { chooseOutput() }
                    }
                }
            }

            if isExporting {
                ProgressView(value: progress) {
                    Text("書き出し中… \(percentText)")
                        .font(.caption)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let finishedURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("完了: \(finishedURL.lastPathComponent)").font(.caption)
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([finishedURL])
                    }
                    .buttonStyle(.link)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if isExporting {
                    Button("中止") {
                        exporter?.cancel()
                    }
                } else {
                    Button("閉じる") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("書き出す") { chooseOutputIfNeededAndStart() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.duration <= 0)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }

    /// 進み具合の百分率。"%" を付けた文字列を先に作って渡す。
    /// リテラルの "%" を訳のキーに混ぜると書式指定子と紛れる。
    private var percentText: String {
        "\(Int(progress * 100))%"
    }

    private var estimate: String {
        let bitrate = settings.videoBitrate(canvas: canvas) + settings.audioBitrate
        let bytes = Int(Double(bitrate) / 8 * store.duration)
        return L("\(bitrate / 1_000_000) Mbps · 約 \(Format.fileSize(bytes))")
    }

    /// 出力先は決め打ちにせず、毎回標準の保存パネルで選んでもらう。
    ///
    /// 以前はプロジェクトの隣かムービーフォルダを最初から選んでいたが、Sandbox の
    /// 下ではどちらも書けない（ムービーフォルダはコンテナの中を指す）うえ、
    /// App Review で決め打ちの場所として指摘された（Guideline 2.4.5(i)）。
    /// パネルで選んだ場所は、このセッションの間は Sandbox の下でも書ける。
    @discardableResult
    private func chooseOutput() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let name = store.project.name.isEmpty ? "movie" : store.project.name
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "\(name).mp4"
        // 開いたときの場所の提案だけ。どこに置くかはユーザーが決める。
        if let dir = outputURL?.deletingLastPathComponent() ?? store.baseURL {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        outputURL = url
        return true
    }

    /// 出力先をまだ選んでいなければ、先にパネルを出す。キャンセルなら何もしない。
    private func chooseOutputIfNeededAndStart() {
        if outputURL == nil {
            guard chooseOutput() else { return }
        }
        start()
    }

    private func start() {
        guard let outputURL else { return }
        errorText = nil
        finishedURL = nil
        progress = 0
        isExporting = true
        store.pause()

        let instance = Exporter()
        exporter = instance
        let project = store.project
        let base = store.baseURL

        Task {
            do {
                try await instance.export(project: project, baseURL: base, to: outputURL,
                                          settings: settings) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run {
                    isExporting = false
                    finishedURL = outputURL
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
