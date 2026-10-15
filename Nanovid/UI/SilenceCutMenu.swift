import SwiftUI

/// 無音カットの強さを選ぶ項目。ツールバーと「編集操作」メニューで同じものを出す。
struct SilenceCutMenuItems: View {
    let store: EditorStore

    var body: some View {
        Button("控えめ（1 秒以上の間）") { run(.gentle) }
        Button("標準（0.5 秒以上の間）") { run(.standard) }
        Button("詰め気味（0.3 秒以上の間）") { run(.tight) }
    }

    private func run(_ options: SilenceDetection.Options) {
        Task { @MainActor in
            do {
                if try await store.cutSilence(options: options) == 0 {
                    store.buildError = L("詰められる無音は見つかりませんでした。")
                }
            } catch {
                store.buildError = error.localizedDescription
            }
        }
    }
}
