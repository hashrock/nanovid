# nanovid website

ビルド不要の静的サイト。`index.html` をブラウザで開いて確認できます。

- `index.html`: ページ本文
- `privacy.html`: プライバシーポリシー（日本語と英語）。App Store Connect のプライバシーポリシー URL に使う
- `support.html`: 問い合わせ先とよくある質問（日本語と英語）。App Store Connect のサポート URL に使う
- `style.css`: レスポンシブスタイル
- `assets/`: ロゴとスクリーンショット

## GitHub Pages

リポジトリの Settings → Pages → Build and deployment → Source で **GitHub Actions** を選択してください。
`main` にマージすると `.github/workflows/pages.yml` が `website/` を公開します。Actions から手動実行も可能です。

Mac App Store のバッジ（公式の日本語・黒）は、Mac App Store の製品ページへリンクしています。公証済みの Mac 版は、その下の文から最新の GitHub Release へリンクしています。
手順の参考: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
