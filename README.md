# nanovid

Mac ネイティブの軽量な動画編集ツール。

- **トラック／レイヤー式**・**非破壊** — 元ファイルは一切書き換えない
- **中間ファイルを作らない** — 編集結果は `AVMutableComposition` とカスタムコンポジタ上にだけ存在し、実ファイルになるのは書き出しの瞬間だけ
- **テキストレイヤーはテンプレート再利用** — レイアウトをテンプレートとして持ち、インスタンス側で props（文字列・色など）を上書き。一括編集にも対応
- 入力: MP4 / MOV / WAV / MP3 / 画像　出力: MP4 (H.264 / HEVC + AAC)
- マイク録音あり・画面録画なし

## ビルドと実行

```sh
open Nanovid.xcodeproj        # Xcode から ⌘R
# もしくは
xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug build
```

ユニットテスト（Swift Testing、82 件）:

```sh
xcodebuild test -project Nanovid.xcodeproj -scheme Nanovid   # Xcode からは ⌘U
```

目盛りの刻み幅・座標変換の往復・ドラッグの吸着と冪等性・ズーム時のスクロール位置・
分割／トリム・フェード計算・テンプレートの props 解決・プロジェクトの保存読込・
合成命令の連続性などを検証している。

起動時にプロジェクトを開く / 動作確認用のプロジェクトを書き出す:

```sh
Nanovid --open path/to/project.nanovid
Nanovid --write-demo <出力ディレクトリ>     # テキストを並べたデモを作って終了
```

描画から書き出しまでを GUI なしで通すテスト:

```sh
"$(xcodebuild -project Nanovid.xcodeproj -scheme Nanovid -configuration Debug \
   -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/Nanovid.app/Contents/MacOS/Nanovid" \
   --selftest /tmp/nanovid-selftest
```

## 構成

```
Nanovid/
  Model/      編集モデル（すべて値型・Codable）
    CoreTypes.swift       CanvasSpec / RGBAColor / Transform2D / Fade
    Project.swift         Project → Track → Clip
    TextTemplate.swift    テンプレート・props・ノード定義
    BuiltinTemplates.swift 同梱テンプレート（字幕・シンプル字幕・テロップ・タイトル）
  Render/     AVFoundation への変換と描画
    CompositionBuilder.swift  Project → AVMutableComposition + AVVideoComposition
    NanovidCompositor.swift   AVVideoCompositing 実装（Core Image 合成）
    TextRasterizer.swift      CoreText でテキストを CGImage 化（キャッシュ付き）
    RenderLayer.swift         区間ごとの合成命令
    Exporter.swift            AVAssetReader → AVAssetWriter
  Store/      状態管理
    EditorStore.swift     編集状態・再生・undo
    EditorCommands.swift  分割／トリム／移動／一括編集などの操作
    ProjectIO.swift       .nanovid（JSON）の読み書き
    AssetCache.swift      AVURLAsset の使い回し
    AudioRecorder.swift   マイク録音（WAV 直書き）
  UI/         SwiftUI
    TimelineTicks.swift   目盛りの刻み幅とスクロール計算（純ロジック・テスト対象）
  Resources/
    blank.mp4   16×16・60秒の黒素材（後述）
```

### 描画の流れ

```
元ファイル（参照のみ）
   ↓
AVMutableComposition        ← クリップを合成トラックへ配置（トラックは使い回す）
   ↓  AVVideoComposition + NanovidInstruction（区間ごとのレイヤー一覧）
NanovidCompositor           ← Core Image で背景・映像・テキストを 1 枚に合成
   ↓
AVPlayer（プレビュー） / AVAssetWriter（書き出し）
```

プレビューと書き出しが同じコンポジタを通るので、見た目は必ず一致する。

### blank.mp4 について

AVFoundation のビデオコンポジションは、合成対象の映像トラックにフレームが
存在しない区間では出力を止めてしまう。テキストだけの区間やクリップ間の
ギャップでも確実にフレームを出すため、16×16 の黒素材をタイムライン全域に
敷いて土台にしている（合成レイヤーとしては使わないので画面には出ない）。
テンポラリではなくアプリ同梱のリソース。

### 座標系

レイアウトは解像度に依存しないよう、すべてキャンバスサイズに対する比で持つ。

- `Transform2D.position` — キャンバス中心を原点とした比（x は右が正、y は下が正）
- `RelFrame` — キャンバス左上を (0,0)、右下を (1,1) とするアンカー配置
- `FontSpec.relativeSize` — キャンバス高さに対する比

そのため 1920×1080 で作ったテンプレートを 1080×1920 に切り替えても崩れない。

## 主な操作

| 操作 | キー |
|---|---|
| 再生 / 一時停止 | Space（タイムラインにフォーカス時）/ ⌘K |
| 分割 | S / ⌘B |
| 複製 | D / ⌘D |
| 削除 | Delete / ⌘Delete |
| 1 フレーム移動 | ← → （Shift で 10 フレーム）|
| 1 秒移動 | J / L |
| ズーム | + / - 、全体を表示は F |

修飾キーなしのキーはタイムラインにフォーカスがあるときだけ効く。テキスト入力中に
誤発火しないようにするため。

### タイムラインのマウス操作

| 操作 | 動作 |
|---|---|
| ホイール / 二本指スワイプ | パン（縦に動かす先が無ければ横へ回す）|
| ⇧ + ホイール | 横パン固定 |
| ⌘ または ⌥ + ホイール | ズーム（カーソル位置の時刻が動かない）|
| ピンチ | ズーム |
| クリップの本体をドラッグ | 移動（上下でトラック間も移動）|
| クリップの端をドラッグ | 長さを調整（素材の残り尺で頭打ち）|
| 目盛りをドラッグ | シーク |
| レーンを右クリック | その位置にテキスト・素材を追加 |

ドラッグ中は他のクリップの端・再生ヘッド・原点に吸着する。効かないときはフレーム境界へ丸める。

横スクロールは `ScrollView` ではなく自前のオフセットで持っている。カーソル位置の時刻を
保ったままズームするには、倍率とスクロール位置を同時に決める必要があるため
（`TimelineScroll.anchoredScrollX`）。

### タイムラインの座標系

扱う座標系は 2 つだけ。取り違えるとクリップと目盛りがずれるので、変換は必ず
`TimelineScroll` を通す（`TimelineView` 内に生の掛け算を書かない）。

| 座標系 | 定義 | 使う場所 |
|---|---|---|
| 内容座標 (content) | `x = 時刻 × pixelsPerSecond` | クリップの配置、ドロップ位置 |
| 表示座標 (viewport) | `x = 内容座標 − scrollX` | 目盛り、再生ヘッド、ポインタ位置 |

クリップのドラッグは、レーン表示領域に張った名前付き座標空間
（`TimelineView.laneSpaceName`）でポインタの**絶対位置**を測り、掴んだ瞬間のズレ
（`grabOffset`）を引いて移動先を決める（`TimelineSnap.resolve`）。

ジェスチャ既定のローカル空間で相対移動量を測ってはいけない。ドラッグ対象は
`.offset` で動くので、「ビューが動く → 測り直す → また動く」というフィードバックに
なり、クリップが左右に振動する。掴んだ基準は `value.location` ではなく
`value.startLocation` から取る（最初のイベントが届く時点でポインタは
`minimumDistance` ぶん進んでいるため）。

## プロジェクトファイル

`.nanovid` は JSON。素材はパス参照のみで、プロジェクトファイルと同じ階層以下に
あるものは相対パスで保存されるので、フォルダごと移動しても開ける。
