import AppKit
import SwiftUI

@main
struct NanovidApp: App {

    /// ユニットテストの中で動いているか。
    ///
    /// テストの置き場はアプリ本体（TEST_HOST）なので、走らせるとアプリごと
    /// 立ち上がる。窓が出てきて前面を奪うと、作業の邪魔になるうえに
    /// キー入力やフォーカスの取り合いでテスト自体も不安定になる。
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

    init() {
        if Self.isRunningTests {
            // Dock にもメニューバーにも出さない。窓も開かない。
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        _ = SelfTest.runIfRequested()
        _ = SelfTest.writeDemoIfRequested()
        _ = SelfTest.transcribeIfRequested()
        _ = SelfTest.inspectIfRequested()
    }

    /// `Nanovid --open <ファイル>` で起動時にプロジェクトを開く。
    private func openProjectFromArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), args.count > i + 1 else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        store.open(url: url)
    }

    @State private var store = EditorStore()

    /// タイムラインの吸着。切り替えをここに置き、TimelineView とは
    /// 同じ保存先を読む。ツールバーに絵柄で置くと何のアイコンか伝わりにくい。
    @AppStorage(TimelineView.snappingKey) private var snappingEnabled = true

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear(perform: openProjectFromArguments)
        }
        // テスト中は最初の窓を開かせない。
        .defaultLaunchBehavior(Self.isRunningTests ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") { store.newProject() }
                    .keyboardShortcut("n")
                Button("開く…") { store.openProject() }
                    .keyboardShortcut("o")
                Divider()
                // 開いたときの案内を「あとで」にした場合の入口。
                Button("素材の場所を指定…") { store.locateMissingMedia() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.save() }
                    .keyboardShortcut("s")
                Button("別名で保存…") { store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("取り消す") { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(!store.canUndo)
                Button("やり直す") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
            // メニューのショートカットはすべて修飾キー付きにしてある。
            // 修飾なしの space / S / 矢印 / delete は、文字入力を邪魔しないよう
            // タイムラインにフォーカスがあるときだけ効く（TimelineView の onKeyPress）。
            CommandMenu("編集操作") {
                // ショートカットは付けない。メニューに ⌘C を載せると常に有効に
                // なってしまい、文字入力中のコピー＆ペーストを奪う。
                // タイムラインにフォーカスがあるときだけ効くよう、
                // TimelineView の onKeyPress で受けている。
                Button("クリップをコピー (⌘C)") { store.copySelection() }
                    .disabled(store.selectedClipIDs.isEmpty)
                Button("クリップを切り取り (⌘X)") { store.cutSelection() }
                    .disabled(store.selectedClipIDs.isEmpty)
                // クリップボードの中身は観測できないので、有効・無効は付けない。
                // 中身が無ければ何も起きない。
                Button("クリップを貼り付け (⌘V)") { store.paste() }
                Divider()
                Button("再生 / 一時停止") { store.togglePlay() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("分割") { store.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("複製") { store.duplicateSelection() }
                    .keyboardShortcut("d")
                // ここから下はショートカットを付けない。⌘A（全選択）、
                // ⌘←→（行頭・行末）、⌘Delete（行頭まで削除）は、いずれも
                // 標準のテキスト編集が使うキー。メニューに載せると常に有効に
                // なり、字幕の入力欄から奪ってしまう。
                // タイムラインにフォーカスがあるときだけ効くよう onKeyPress で受ける。
                Button("切り抜き開始 (Q)") { store.markExtractStart() }
                Button("切り抜いて詰める (W)") { store.extractMarkedRange() }
                    .disabled(store.extractStart == nil)
                Button("切り抜きをやめる") { store.cancelExtract() }
                    .disabled(store.extractStart == nil)
                Divider()
                Button("削除 (Delete)") { store.deleteSelection() }
                    .disabled(store.selectedClipIDs.isEmpty)
                Button("削除して詰める") { store.rippleDeleteSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(store.selectedClipIDs.isEmpty)
                Button("隙間を詰める") { store.packSelection() }
                    .disabled(store.selectedClipIDs.count < 2)
                Divider()
                Button("すべて選択 (⌘A)") { store.selectAll() }
                Button("選択を解除 (⇧⌘A)") { store.selectedClipIDs = [] }
                    .disabled(store.selectedClipIDs.isEmpty)
                Divider()
                Button("1 フレーム戻る (←)") { store.step(frames: -1) }
                Button("1 フレーム進む (→)") { store.step(frames: 1) }
                Divider()
                // ドラッグの最中に ⌥ を押すと、そのあいだだけこの設定と逆になる。
                Toggle("クリップを吸着させる", isOn: $snappingEnabled)
                Divider()
                Button("映像トラックを追加") { store.addTrack(kind: .video) }
                Button("音声トラックを追加") { store.addTrack(kind: .audio) }
            }
        }
    }
}
