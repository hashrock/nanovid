// App Store 用ビルドには入れない（README「App Store 用ビルドと MCP」）。
#if !APPSTORE
import AppKit
import SwiftUI

/// MCP のメニューと、入切に合わせたサーバの上げ下げ。
///
/// アプリ本体（NanovidApp）から MCP に触るのはこの 2 つだけにしてある。
/// App Store 用ビルドではこのフォルダごとコンパイルから外れる。
///
/// 文言は Localizable ではなく MCP.xcstrings（表の名前は "MCP"）に置く。
/// App Store 用ビルドでは表ごと同梱しないので、アプリの中に MCP の文字が残らない。
enum MCPStrings {
    static let table = "MCP"

    static func L(_ value: String.LocalizationValue) -> String {
        String(localized: value, table: table)
    }
}

/// アプリのメニュー（設定の下）に置く項目。
struct MCPCommands: Commands {
    /// AI から MCP で操作できるようにするか（MCPServer）。既定は切ってある。
    @AppStorage(MCPServer.enabledKey) private var enabled = false

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle(isOn: $enabled) {
                Text("AI から操作できるようにする (MCP)", tableName: MCPStrings.table)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCPServer.endpoint, forType: .string)
            } label: {
                Text("MCP の接続先をコピー", tableName: MCPStrings.table)
            }
            .disabled(!enabled)
        }
    }
}

/// メニューの入切に合わせて MCP サーバを動かし、編集先の store を渡す。
struct MCPServerLink: ViewModifier {
    let store: EditorStore
    @AppStorage(MCPServer.enabledKey) private var enabled = false

    func body(content: Content) -> some View {
        content.onChange(of: enabled, initial: true) {
            let server = MCPServer.shared
            server.store = store
            guard enabled, !NanovidApp.isRunningTests else { return server.stop() }
            server.start { reason in
                enabled = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = MCPStrings.L("MCP サーバを始められませんでした")
                alert.informativeText = MCPStrings.L("ポート \(String(MCPServer.port)) を使えませんでした。ほかのアプリが使っているかもしれません。\n\(reason)")
                alert.runModal()
            }
        }
    }
}
#endif
