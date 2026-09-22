import Foundation

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

// 訳は Nanovid/Localizable.xcstrings に入っている。ソース言語は日本語で、
// コード上のリテラルがそのままキーになる。SwiftUI 側のリテラルは Xcode が
// 拾ってくれるが、この `L` を通したものは拾われないので、新しい文言を
// 足したときはカタログ側にも自分で一行足す。
