import Testing
import Foundation

/// テストの層分け。
///
/// 普段は関数レベルの速いテストだけを走らせたい。合成を組んで絵を描くもの、
/// 実ファイルを AVFoundation に読ませるものは、通してもほとんど落ちないのに
/// 一番時間を食う。そこで重いものは既定では飛ばし、CI で全部を走らせる。
///
///     Scripts/test.sh          速い層だけ
///     Scripts/test.sh --all    全部（CI と同じ）
///
/// 切り替えは環境変数 `NANOVID_TESTS`。xcodebuild へは
/// `TEST_RUNNER_NANOVID_TESTS=all` の形で渡すと、テストを動かす側の
/// プロセスに入る。Xcode から全部走らせたいときはスキームの Test →
/// Arguments に同じ名前で `all` を足す。
enum TestTier {

    /// 重い層も走らせるか。
    static let runsEverything = ProcessInfo.processInfo.environment["NANOVID_TESTS"] == "all"

    /// 重い層に付ける条件。飛ばした理由が実行結果に残る。
    static var heavy: ConditionTrait {
        .enabled(if: runsEverything,
                 "重い層。Scripts/test.sh --all（NANOVID_TESTS=all）のときだけ走る")
    }
}

extension Tag {
    /// 合成を組んで実際に描くもの。AVFoundation と Metal を起こす。
    @Tag static var render: Self
    /// 実ファイルを AVFoundation に読ませるもの。
    @Tag static var media: Self
}

/// 性質テストの回し数。
///
/// 速い層では間引く。種は 0 から順に使うので、間引いても残った種の結果は
/// 変わらない（落ちた種をそのまま例示テストへ固定できる）。全部の種は CI で
/// 回る。
enum PropertyRuns {
    static func seeds(_ count: Int) -> Range<Int> {
        TestTier.runsEverything ? 0..<count : 0..<max(1, count / 4)
    }
}
