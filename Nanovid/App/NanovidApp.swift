import SwiftUI

@main
struct NanovidApp: App {
    init() {
        _ = SelfTest.runIfRequested()
        _ = SelfTest.writeDemoIfRequested()
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

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear(perform: openProjectFromArguments)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") { store.newProject() }
                    .keyboardShortcut("n")
                Button("開く…") { store.openProject() }
                    .keyboardShortcut("o")
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
                Button("再生 / 一時停止") { store.togglePlay() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("分割") { store.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("複製") { store.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("削除") { store.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("削除して詰める") { store.rippleDeleteSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                Button("隙間を詰める") { store.packSelection() }
                    .disabled(store.selectedClipIDs.count < 2)
                Divider()
                Button("すべて選択") { store.selectAll() }
                    .keyboardShortcut("a")
                Button("選択を解除") { store.selectedClipIDs = [] }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("1 フレーム戻る") { store.step(frames: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("1 フレーム進む") { store.step(frames: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("映像トラックを追加") { store.addTrack(kind: .video) }
                Button("音声トラックを追加") { store.addTrack(kind: .audio) }
            }
        }
    }
}
