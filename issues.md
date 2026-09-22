# 既知の問題と、調べて分かったこと

AVFoundation に乗っている代償の記録。直したものも、直していないものも、
「起きなかった」と確かめたものも書く。次に黒い画面を見たときに、ここから当たる。

数字は 2026-09-22 に手元（Apple Silicon、macOS 26）で測ったもの。

## 直したもの

### プレビューが真っ暗になる（命令列の隙間）

**症状** — 特定のプロジェクトでプレビューが黒いまま。エラーは出ない。

**原因** — 区間の境界を Double のまま集めていた。`2.1 + 25.0/30` と `88.0/30` は
差 4.4e-16 だが、600 分の 1 秒へ落とすと 1760 と 1759 に分かれる。「ほぼ同じだから」と
片方を捨てたところに 600 分の 1 秒の隙間が空き、AVFoundation は命令列が合成の全域を
覆っていないと何も描かない。

**対処** — 境界を先に CMTime へ落としてから重複を除く（`InstructionPlan`）。
性質テストが、同じフレーム数を違う経路で計算して下位ビットのずれた時刻を作り、
区間が隙間なく覆うことを見張る。修正前の実装に戻すと 3 つの性質が落ちる。

### 静止した区間のフレームが足りない

**症状** — テロップだけの 3 秒を書き出すと 3 フレームしか無い。区間が 1 つしか無いと
尺そのものも狂う（1 秒が 0.07 秒になる）。

**原因** — `NanovidInstruction.containsTweening` がフェードのあるときだけ true だった。
false だと AVFoundation は「中身が動かない区間」に 1 枚しかフレームを要求しない。
再生ではそれでよいが、書き出すとフレーム数が中身次第になる。

**対処** — 書き出し時は `constantFrameRate: true` で必ず毎フレーム描く。
自己テストの全出力が `fps × 尺` ちょうどのフレーム数になることを確かめる。

### 書き出す範囲を切り出すと、フェードの途中で画が変わる

**症状** — 範囲の頭がフェードインの最中にあると、書き出しではそこから改めて 0 から
立ち上がる。プレビューと画が違う。

**原因** — `Fade` はクリップの端からの長さしか持たず、途中から始まるフェードを表せない。
端を切り詰めると、切った先が新しい端になる。

**対処** — 端を落とすのはフェードが終わったあとでだけ（`croppedToOutputRange`）。
性質テスト「切り出しても範囲の中の見え方は変わらない」と、ヘッドレス描画の画素比較の
両方で見る。修正前の実装では画素差 13.25（閾値 0.5）で落ちる。

### 再生できない素材が黙って黒くなる

**症状** — 対応外のコーデック（FFV1 / HuffYUV / VP9）や、途中で切れたファイルを
取り込むと、プレビューは黒いまま。エラーは出ない。

**分かったこと** — `AVPlayerItem.status` は `.failed` にならない。`readyToPlay` を返し、
最後まで時間だけ進む。`failedToPlayToEndTime` も飛ばない。開いたあとにファイルを消しても
同じ（ハンドルが生きている）。**プレイヤー側を見張っても拾えない。**

| 壊れ方 | `isPlayable` / `isDecodable` | 実際のデコード |
|---|---|---|
| 対応外コーデック | false | 失敗 -11869 |
| 途中で切れたファイル | true | 切れた先だけ失敗 -11821 |

**対処** — 取り込みの時点で実際にデコードを試す（`AssetCache.inspect`）。対応外は
`isDecodable` で分かる。途中で切れたものはフラグでは分からないので末尾付近のフレームを
1 枚読む（6 分の素材でも 0.1 秒）。組み立て（`CompositionBuilder`）でも `isDecodable` を
見る。別の Mac で作ったプロジェクトを開くと、検査を通っていない素材が入ってくるため。
プレイヤーの監視も残してあるが、当てにしていない。

### 組み直しのあとのシークが戻らない

**症状（未発生、報告のみ）** — `seekingWaitsForVideoCompositionRendering = true` を
立てていると、`seek` の完了が二度と呼ばれないことがある。Apple のエンジニアが
「想定外の挙動」と認めたうえで未修正（FB9877123）。

**当てはまり方** — `rebuild` が組み直すたびにこの完了を `await` していた。起きると
rebuild が戻らず `isBuilding` が立ったままになる。

**対処** — 1 秒を上限に待ち、来なければ先へ進む（`seekBounded`）。普段は数十 ms で済む。

## 直していないもの

### `AVAssetReader.startReading()` が -11841 を返す

範囲の先頭を 0 秒へずらした合成を組むと、`startReading()` が -11841
（不正な映像合成）を返す組み合わせがあった。正常に動くケースと**合成の中身が
完全に同一**（命令列・トラック・尺・renderSize・frameDuration を全部比べた）のまま、
片方だけ落ちる。`isValid(for:timeRange:validationDelegate:)` は true を返す。
**原因は分かっていない。**

時刻を動かさず範囲外のクリップだけ落とす方式に変えて回避した。同じ構造が別の形で
出たら、また手探りになる。

### `AVAssetReader.timeRange` が映像合成の出力と噛み合わない

`timeRange` で読む範囲を切ると、`AVAssetReaderVideoCompositionOutput` が命令の切れ目でしか
フレームを出さない（0.0 / 1.0 / 2.0 秒の 3 枚だけ）。使っていない。

### 素材フレームが nil のときは背景を出す

コンポジタは `sourceFrame(byTrackID:)` が nil のレイヤーを飛ばす。ネットには
「ゼロ許容のシークで時々 nil になる」報告があり（未回答）、もし起きればスクラブ中に
一瞬背景がちらつく。手元ではシーク 178 回で 0 回だったので保留。直すなら直前の
フレームを覚えておいて使い回す（20 行ほど）。

## 手元で再現しなかった報告

| 報告 | 確かめ方 | 結果 |
|---|---|---|
| ゼロ許容のシークで `sourceFrame(byTrackID:)` が時々 nil | 目盛りの往復ドラッグ＋←→連打 | シーク 178 回、nil 0 回 |
| 60fps を指定してもコマが飛ぶ | 2 秒フェード入りの 60fps を再生 | 249 コマ全部が 16.67ms ちょうど |
| `AVURLAssetPreferPreciseDurationAndTimingKey` で MP3 が遅い | 30 分の VBR MP3 を取り込む | Xing 無し 0.14 秒、有り 0.03 秒 |
| `AVAssetWriter` の音声・映像の割り込み待ちでハング | 自己テストの音声付き書き出し | 通る（Apple のサンプルと同じ別キュー並行） |

## 覚えておくこと

- **Xcode 27 beta** で、カスタムコンポジタに要求が届く前に合成が拒否される報告がある
  （-11800 / -12784、回避策なし）。ツールチェーンの回帰と見られている。上げるときは
  `--selftest` を先に通す。
- **SpeechAnalyzer** の言語モデル取り寄せは最長 15 分。前回の中断で `status` が
  `.downloading` のまま残ることがある。一部の言語で「取り寄せたのに見つからない」に
  なる報告もある。どれも `buildError` に出る。
- **AVFoundation の失敗は「黒い」「短い」しか出ない。** 数字のエラーコードが出れば
  まだよいほう。だからヘッドレスで 1 フレーム描いて画素で確かめる（`HeadlessRender`）。

## 数字（参考値）

carve.nanovid（クリップ 47 本、うちテキスト 39）で:

| 何 | 時間 |
|---|---|
| 合成の組み立て（初回） | 137〜145 ms |
| 合成の組み立て（2 回目以降） | 2 ms |
| 再生経路で 1 コマ（初回） | 91〜96 ms |
| 再生経路で 1 コマ（2 コマ目以降） | 20〜39 ms |
| 合成だけを直に呼ぶ（文字 2 枚＋背景） | 3.3 ms |
| 書き出し 1080p | 実時間の 4.5 倍速 |

初回の 140 ms はほぼ文字のラスタライズ。1 コマ 20〜39 ms のうち自前の合成は 3 ms で、
残りが AVFoundation の取り分。

## 確かめ方

```sh
# 組み立て・1 コマの描画・命令列の連続性を、プロジェクトを開かずに見る
Nanovid --inspect path/to/movie.nanovid [秒]

# 書き出しを通して、尺・フレーム数・範囲の画素一致・倍速を見る
Nanovid --selftest /tmp/nanovid-selftest

# 性質テストとヘッドレス描画テスト
xcodebuild test -project Nanovid.xcodeproj -scheme Nanovid
```

## 出典

- [Xcode 27 beta can reject composition-backed playback before a custom AVVideoCompositor receives requests](https://github.com/chinhbui/apple-platform-issue-guide/issues/23)
- [AVPlayer seek completion handler not called (FB9877123)](https://developer.apple.com/forums/thread/699613)
- [sourceFrame(byTrackID:) returns nil sometimes while seeking](https://developer.apple.com/forums/thread/689369)
- [AVPlayer with customCompositor sometimes crashes on seeking](https://developer.apple.com/forums/thread/689741)
- [Custom Video Compositor Skipping Frames Despite 60 FPS](https://developer.apple.com/forums/thread/805521)
- [QA1820: How do I achieve smooth video scrubbing with AVPlayer seekToTime:?](https://developer.apple.com/library/archive/qa/qa1820/_index.html)
- [SpeechAnalyzer "asset not found after attempted download"](https://developer.apple.com/forums/thread/797835)
- [isReadyForMoreMediaData and AVAssetWriterInput](https://developer.apple.com/forums/thread/718433)
- [AVURLAssetPreferPreciseDurationAndTimingKey の実測（kuulla）](https://github.com/two4suited/kuulla/issues/774)
