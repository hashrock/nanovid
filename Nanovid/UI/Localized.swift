import Foundation
import SwiftUI

/// 文字列を直に組み立てる側のためのローカライズ入口。
///
/// SwiftUI の `Text` / `Button` / `Label` などは文字列リテラルを
/// `LocalizedStringKey` として受け取るので、リテラルを書いた時点で
/// `Localizable.xcstrings` の訳が当たる。困るのはそこを通らない側で、
/// - AppKit のアラートやパネル（`NSAlert.messageText` など）
/// - `Error` の `errorDescription`
/// - enum の表示名のように `String` を返して `Text(someString)` に渡すもの
///   （この初期化子はキー探索をせず、そのまま出してしまう）
/// はいずれも自分で引かないと訳が当たらない。そこをこの関数で揃える。
///
/// 補間もそのまま書ける。`L("素材が見つかりません: \(name)")` のキーは
/// `素材が見つかりません: %@` になり、コンパイラが生成するものと一致する。
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// 文書に保存された表示名を、表示のときに訳す。
///
/// 同梱テンプレートの名前・レイヤー名・props の表示名は、作った時点で訳して
/// しまうと英語環境で作った .nanovid が日本語環境でも英語のまま固まる。
/// そこで保存する側は原語（日本語）のまま置き、出すときにここで引く。
/// ユーザーが自分で付けた名前はカタログに無いので、そのまま返る。
///
/// `L` と違って実行時の値を渡すので、書式指定子の解釈を挟まない
/// `Bundle.localizedString` を使う。ファイル名など何が来ても素通しになる。
func LName(_ stored: String) -> String {
    guard !stored.isEmpty else { return stored }
    return Bundle.main.localizedString(forKey: stored, value: stored, table: nil)
}

extension Binding where Value == String {
    /// 保存名を打ち替える欄のための橋渡し。表示は `LName` で訳して出し、
    /// 打ち込まれたものはそのまま保存する。触らなければ書き戻りは起きないので、
    /// 原語のまま置いてある名前が英語環境で開いただけで英語に焼き付くことはない。
    func localizedName() -> Binding<String> {
        Binding(get: { LName(self.wrappedValue) }, set: { self.wrappedValue = $0 })
    }
}

// 訳は Nanovid/Localizable.xcstrings に入っている。ソース言語は日本語で、
// コード上のリテラルがそのままキーになる。SwiftUI 側のリテラルは Xcode が
// 拾ってくれるが、この `L` / `LName` を通したものは拾われない。代わりに
// Scripts/check-localization.py が取りこぼしと未訳を見張っていて、
// Scripts/test.sh と CI から走る。
