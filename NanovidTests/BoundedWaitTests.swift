import Testing
import Foundation
@testable import Nanovid

/// プレビューの組み直しで使う「待ちすぎない」待ち。
/// 完了が来ないシーク（FB9877123）でも組み直しが戻ってくること。
struct BoundedWaitTests {

    private func elapsed(_ body: () async -> Void) async -> Double {
        let start = Date()
        await body()
        return Date().timeIntervalSince(start)
    }

    @Test("完了の知らせが来なくても、時間切れで先へ進む")
    func timesOutWithoutCompletion() async {
        let t = await elapsed {
            await EditorStore.waitBounded(timeout: 0.2) { _ in }
        }
        // 戻ってくること自体が確かめたいこと。上限は、ほかの重いテストと並んで
        // スレッドが詰まると大きくずれるので見ない。
        #expect(t >= 0.15)
    }

    @Test("完了の知らせが来れば時間切れを待たない")
    func returnsOnCompletion() async {
        let t = await elapsed {
            await EditorStore.waitBounded(timeout: 120) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done() }
            }
        }
        // 並んで走るテストで詰まっても、時間切れ（120 秒）よりはずっと早く戻る。
        #expect(t < 60)
    }

    @Test("完了を何度知らせても、時間切れと重なっても落ちない")
    func toleratesRepeatedCompletion() async {
        await EditorStore.waitBounded(timeout: 0.05) { done in
            done()
            done()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done() }
        }
        // 時間切れのあとの知らせも空振りするだけ。
        try? await Task.sleep(for: .milliseconds(150))
    }
}
