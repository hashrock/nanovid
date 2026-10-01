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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// ヘルプメニューから開くページ。
    static let supportURL = URL(string: "https://hashrock.github.io/nanovid/")!

    /// タイムラインの吸着。切り替えをここに置き、TimelineView とは
    /// 同じ保存先を読む。ツールバーに絵柄で置くと何のアイコンか伝わりにくい。
    @AppStorage(TimelineView.snappingKey) private var snappingEnabled = true
    /// AI から MCP で操作できるようにするか（MCPServer）。既定は切ってある。
    @AppStorage(MCPServer.enabledKey) private var mcpEnabled = false

    var body: some Scene {
        // 1 プロジェクトを 1 つの窓で編集する作り。窓を閉じたら終了する
        // （AppDelegate）。
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear(perform: openProjectFromArguments)
                .modifier(AppDelegateLink(delegate: appDelegate, store: store))
                .modifier(MCPServerLink(store: store, enabled: $mcpEnabled))
        }
        // テスト中は最初の窓を開かせない。
        .defaultLaunchBehavior(Self.isRunningTests ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appSettings) {
                Toggle("AI から操作できるようにする (MCP)", isOn: $mcpEnabled)
                Button("MCP の接続先をコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPServer.endpoint, forType: .string)
                }
                .disabled(!mcpEnabled)
            }
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
                // .saveItem を置き換えると標準の「閉じる」も消えるので置き直す。
                // 窓を閉じると終了する（AppDelegate）。
                Button("閉じる") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
                Button("保存") { store.save() }
                    .keyboardShortcut("s")
                Button("別名で保存…") { store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // 何も置かないと「ヘルプは利用できません」と出るだけの項目が残る。
            CommandGroup(replacing: .help) {
                Button("Nanovid のサポート") { NSWorkspace.shared.open(Self.supportURL) }
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

/// 窓を閉じたら終了し、閉じる・終了する前に未保存の変更を確かめる。
///
/// 窓を閉じたあと開き直す手段が無い、と App Review で指摘された（Guideline 4）。
/// 1 プロジェクト 1 窓なので、閉じたら終了にする。
///
/// 確認は窓を閉じる前に、その窓へシートで出す（標準の書類アプリと同じ）。
/// キャンセルなら窓はそのまま残る。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 窓が出たときに AppDelegateLink が渡す。
    weak var store: EditorStore?
    private weak var mainWindow: NSWindow?
    private var closeGuard: WindowCloseGuard?

    /// 窓を閉じる確認が済んだ。続く終了で同じことを聞き直さない。
    private var discardConfirmed = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !NanovidApp.isRunningTests
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !discardConfirmed, store.hasUnsavedChanges else { return .terminateNow }
        guard let window = mainWindow, window.isVisible else {
            return store.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
        }
        // 閉じる確認のシートが出ているあいだの ⌘Q は、そちらに任せる。
        if window.attachedSheet != nil { return .terminateCancel }
        store.confirmDiscardIfNeeded(in: window) { ok in
            sender.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    /// メインの窓の delegate を包み、閉じる前の確認を差し込む。
    @MainActor
    func attach(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        mainWindow = window
        let guard_ = WindowCloseGuard(wrapping: window.delegate) { [weak self] window in
            self?.shouldClose(window) ?? true
        }
        closeGuard = guard_
        window.delegate = guard_
    }

    @MainActor
    private func shouldClose(_ window: NSWindow) -> Bool {
        guard let store, !discardConfirmed, store.hasUnsavedChanges else { return true }
        store.confirmDiscardIfNeeded(in: window) { [weak self] ok in
            guard ok else { return }
            self?.discardConfirmed = true
            window.close()
        }
        return false
    }
}

/// 窓の delegate を包んで windowShouldClose だけ差し替える。
/// ほかの知らせはもとの delegate（SwiftUI のもの）へそのまま流す。
private final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool

    init(wrapping original: NSWindowDelegate?, shouldClose: @escaping (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}

/// SwiftUI 側の store と窓を AppDelegate へ渡す。
private struct AppDelegateLink: ViewModifier {
    let delegate: AppDelegate
    let store: EditorStore

    func body(content: Content) -> some View {
        content
            .onAppear { delegate.store = store }
            .background(WindowReader { delegate.attach($0) })
    }
}

/// メニューの入切に合わせて MCP サーバを動かし、編集先の store を渡す。
private struct MCPServerLink: ViewModifier {
    let store: EditorStore
    @Binding var enabled: Bool

    func body(content: Content) -> some View {
        content.onChange(of: enabled, initial: true) {
            let server = MCPServer.shared
            server.store = store
            guard enabled, !NanovidApp.isRunningTests else { return server.stop() }
            server.start { reason in
                enabled = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("MCP サーバを始められませんでした")
                alert.informativeText = L("ポート \(String(MCPServer.port)) を使えませんでした。ほかのアプリが使っているかもしれません。\n\(reason)")
                alert.runModal()
            }
        }
    }
}

/// 自分が載っている NSWindow を知らせる。
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
