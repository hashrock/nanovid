import Testing
import Foundation
@testable import Nanovid

/// 文言まわり。
///
/// 訳そのものはカタログを見れば分かるので、ここで見るのは「機械が組み立てる
/// ところ」だけ。複数形の切り替わりと、文書に保存される名前が環境の言語に
/// 引きずられないことの 2 つ。
///
/// 走らせる側の言語に左右されないよう、訳は `en.lproj` を名指しで読む。
/// `Bundle.main` はテストホストの Nanovid.app なので、そこに入っている実際の
/// 成果物を見ていることになる。
///
/// 日本語はソース言語で、カタログに訳を持たない。表そのものが作られないので
/// `ja.lproj` は出来上がらず、日本語で出るのはキーの文字列そのものになる。
/// 日本語に単数形が無いこと（`one` の変種を書いても選ばれない）は実行時では
/// なく Scripts/check-localization.py が見ている。
struct LocalizationTests {

    private static func bundle(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"),
                               "\(language).lproj が Nanovid.app に入っていません")
        return try #require(Bundle(url: url))
    }

    /// カタログから引いた書式へ数を入れる。`%#@…@` の展開もここで起きる。
    ///
    /// 単数・複数のどちらを選ぶかは書式ではなくロケールの規則で決まるので、
    /// `localizedStringWithFormat`（＝ `Locale.current`）ではなく言語を名指しする。
    /// 実機では UI の言語とロケールの言語が揃うので、ここだけの話。
    private static func format(_ key: String, _ arguments: CVarArg...,
                               language: String) throws -> String {
        let template = try bundle(language).localizedString(forKey: key, value: nil, table: nil)
        return String(format: template, locale: Locale(identifier: language), arguments: arguments)
    }

    // MARK: - 複数形

    @Test("英語では数が 1 のときだけ単数形になる",
          arguments: [
            ("%lld 件", "1 clip", "3 clips"),
            ("%lld 個", "1 clip", "3 clips"),
            ("%lld 件に適用", "Applies to 1 clip", "Applies to 3 clips"),
            ("使用中: %lld クリップ", "In use: 1 clip", "In use: 3 clips"),
            ("%lld 個のクリップ", "Clip", "3 Clips"),
          ])
    func englishPlural(key: String, one: String, other: String) throws {
        #expect(try Self.format(key, 1, language: "en") == one)
        #expect(try Self.format(key, 3, language: "en") == other)
    }

    @Test("数を 2 つ取る文言でも、複数形になるのは数えている方だけ")
    func englishPluralWithTwoNumbers() throws {
        let key = "%lld props · 使用 %lld"
        #expect(try Self.format(key, 1, 1, language: "en") == "1 prop · 1 in use")
        #expect(try Self.format(key, 3, 1, language: "en") == "3 props · 1 in use")
        #expect(try Self.format(key, 3, 0, language: "en") == "3 props · 0 in use")
    }

    @Test("尺の要約は 1 個のときだけ範囲を出さない")
    func selectionSummaryShapes() throws {
        #expect(try Self.format("1 個 · %@ 秒", "2.0", language: "en") == "1 clip · 2.0 s")
        #expect(try Self.format("%lld 個 · %@ 秒 / 範囲 %@ 秒", 3, "2.0", "5.0", language: "en")
                == "3 clips · 2.0 s / span 5.0 s")
    }

    // MARK: - 文書に保存される名前

    /// 同梱テンプレートの名前は「原語のまま保存して、出すときに訳す」。
    /// ここが崩れると、英語環境で作った .nanovid が日本語環境でも英語のまま固まる。
    @Test("同梱テンプレートの名前は環境の言語によらず原語で入る")
    func builtinNamesStayInSourceLanguage() {
        #expect(TextTemplate.subtitle().name == "字幕")
        #expect(TextTemplate.plainSubtitle().name == "シンプル字幕")
        #expect(TextTemplate.lowerLeftNote().name == "テロップ（左下）")
        #expect(TextTemplate.title().name == "タイトル")

        let subtitle = TextTemplate.subtitle()
        #expect(subtitle.nodes.map(\.name) == ["背景板", "本文"])
        #expect(subtitle.props.map(\.label) == ["テキスト", "文字色", "背景色"])
    }

    /// 保存された名前は表示のときに訳す。カタログに英語が無いと素通しになるので、
    /// 同梱テンプレートが使う名前がひととおり訳されていることを見ておく。
    @Test("同梱テンプレートが使う名前には英語の訳がある")
    func builtinNamesHaveEnglishTranslations() throws {
        let english = try Self.bundle("en")
        let templates = [TextTemplate.subtitle(), TextTemplate.plainSubtitle(),
                         TextTemplate.lowerLeftNote(), TextTemplate.title()]
        var names = Set<String>()
        for template in templates {
            names.insert(template.name)
            names.formUnion(template.nodes.map(\.name))
            names.formUnion(template.props.map(\.label))
        }
        for name in names.sorted() {
            let translated = english.localizedString(forKey: name, value: "", table: nil)
            #expect(!translated.isEmpty, "英語の訳がありません: \(name)")
            #expect(translated != name, "英語の訳が日本語のままです: \(name)")
        }
    }

    @Test("LName はカタログに無い名前をそのまま返す")
    func lNamePassesThroughUnknownNames() {
        #expect(LName("ぼくがつけた名前") == "ぼくがつけた名前")
        #expect(LName("IMG_4821.MOV") == "IMG_4821.MOV")
        #expect(LName("") == "")
        // 書式指定子が混ざっていても解釈されずにそのまま出る。
        #expect(LName("100%@ 完成") == "100%@ 完成")
    }

    /// props の既定値は「動画に描かれる中身」なので、作った時点の言語で確定させる。
    /// 表示名（label）と同じキーを共有していると、片方を直したらもう片方も動く。
    @Test("props の表示名と、動画に描かれる既定値は別のキーを使う")
    func labelAndContentDoNotShareAKey() {
        let text = TextTemplate.subtitle().props.first { $0.key == "text" }
        #expect(text?.label == "テキスト")
        #expect(text?.defaultValue.stringValue != text?.label)
    }
}
