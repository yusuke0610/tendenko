# ADR-0007: 発災時の音声案内をドメイン層の案内文生成 + `.playback`/`.voicePrompt` セッションで実装する

- ステータス: Accepted
- 日付: 2026-08-02
- プロジェクト: tendenko

## コンテキスト

要件定義 (requirements.md §1) はプロダクトの目的を T1 (気付くまで)・T2 (判断)・T3 (移動) の合計時間の短縮と定義し、T3 の短縮アプローチを「迷わない経路 / **音声主体の案内** / 即時リルート」としている。FR-13 は「音声案内は画面を見ずに完走できる粒度で行う (「次の角を右」「この坂を登り切る」)。**音量は端末設定に関わらず最大で再生する**」と規定する。

しかし現状、音声案内は一行も実装されていない。

- requirements.md §6 は「ドメイン層: 経路探索 (標高コスト付きグラフ探索) / **案内文生成** ← 純粋関数・TDD 対象」と位置づけているが、`app/TendenkoDomain/Sources/TendenkoDomain/` に案内文生成のファイルもテストも存在しない。実装済みなのは経路探索側 (`EvacuationRouter.swift`) までである
- `ContentView.computeOverlay()` は経路を計算して地図に描画するが、音は鳴らない。FR-11 が求める「アプリ起動の瞬間に、経路 1 本が地図に表示され**音声が流れている**状態」の音声側が欠落している

一方、経路探索の出力 (`Route.nodeIDs`) と道路グラフ (`RoadGraph` の `bearingDeg` / `grade` / `EdgeFlags`) は揃っており、案内文生成に必要な入力はすべて端末内にある。追加のデータ取得は不要で、地域パッケージフォーマット (ADR-0003) の変更も要らない。

決めるべき論点は 2 つある。**(1) 案内文生成をどの層に置くか**、**(2) FR-13 の「音量最大」を iOS 上でどう実現するか**。とくに (2) は他アプリの音を止める副作用を伴い、かつ後述するとおり要件がそのままでは達成できないため、決定として記録する必要がある。

### 一次情報の確認

ADR-0003 (A40・福井県データ) / ADR-0006 (フォントライセンス) と同じ手順で、挙動を推測せず Apple 公式ドキュメントで確認した。

| 確認先 | 確認できた内容 |
|---|---|
| [`AVAudioSession.outputVolume`](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume) | `var outputVolume: Float { get }` の**読み取り専用**。「**Only the user can directly set the system volume.** Provide a volume control in your app, using `MPVolumeView`, to provide the interface to adjust the system volume.」 |
| [`AVAudioSession.Category.playback`](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback) | 「your app audio continues with the Silent switch set to silent or when the screen locks」。バックグラウンド継続には `UIBackgroundModes` の `audio` が必要。「By default, using this category implies that your app's audio is nonmixable—activating your session will interrupt any other audio sessions which are also nonmixable」 |
| [`AVAudioSession.Mode.voicePrompt`](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voiceprompt) | 「A mode that indicates that your app plays audio using text-to-speech.」「An example of an app that uses this mode is a turn-by-turn navigation app that plays short prompts to the user.」「Typically, apps of the same type also configure their sessions to use the `duckOthers` and `interruptSpokenAudioAndMixWithOthers` options.」 |
| [`AVAudioSession.CategoryOptions`](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions) | `duckOthers` =「reduces the volume of other audio sessions while audio from this session plays」、`interruptSpokenAudioAndMixWithOthers` =「determines whether to pause spoken audio content from other sessions when your app plays its audio」 |

**この確認により、FR-13 の「音量は端末設定に関わらず最大で再生する」は公開 API では文字どおりには達成できないことが確定した。** システム音量はユーザーだけが設定できる。

## 検討した選択肢

### 論点 1: 案内文生成をどの層に置くか

#### 選択肢 1-A: ドメイン層 (`TendenkoDomain`) の純粋関数として実装する

`Route` + `RoadGraph` + 目的地 `Shelter` を入力に、発話地点つきの指示列を返す `public enum GuidanceScript` を置く。`AVFoundation` には依存させず、出力は `String` を含む値型に留める。

- ✅ `make domain-test` (シミュレータ不要・高速) で TDD できる。曲がる方向の判定や距離の丸めは境界条件が多く、テストで固めるべき性質の塊である
- ✅ `.claude/rules/swift.md` の依存境界 (「ドメイン層は純粋関数 + TDD」「サーバー・インフラへの依存を持ち込まない」) と、requirements.md §6 の層定義にそのまま一致する
- ✅ FR-14 (逸脱リルート)・FR-16 (到達検知) で位置追従を足すとき、発話地点 (`nodeID`) を持つ指示列がそのまま使える
- ❌ 日本語の文言がドメイン層にハードコードされる。多言語化する場合は構造 (`Maneuver`) と文言生成を分離し直す必要がある
- 判定: **採用**

#### 選択肢 1-B: UI 層で `AVSpeechSynthesizer` に渡す直前に文字列を組み立てる

- ✅ 文言と読み上げが 1 箇所にまとまり、見通しは一瞬よい
- ❌ 曲がる方向・距離集約・坂判定という**テストすべきロジックがシミュレータ必須の層に落ちる**。`.claude/rules/testing.md` のとおり `make app-test` は CI で実行されておらず、回帰を検出できない場所にロジックを置くことになる
- ❌ requirements.md §6 の層定義に反する
- 判定: 棄却

### 論点 2: 音声セッションの構成 (FR-13「音量最大」の実現手段)

#### 選択肢 2-A: `.ambient` カテゴリで再生する

- ✅ 他アプリの音を一切妨げない
- ❌ **Ring/Silent スイッチがサイレントだと無音になる**。避難案内が鳴らないケースが生まれ、FR-13 の趣旨を根本から満たさない
- 判定: 棄却

#### 選択肢 2-B: `.playback` + mode `.voicePrompt` + options `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]`

- ✅ サイレントスイッチ・画面ロック中でも鳴る (`.playback` の文書化された挙動)
- ✅ Apple が `.voicePrompt` の説明で「turn-by-turn navigation app」を例に挙げ、このオプションの組み合わせを名指しで推奨している構成そのもの。CarPlay 等でのルーティング挙動も期待どおりになる
- ✅ 音楽は音量が下がるだけで停止せず、ポッドキャスト等の音声コンテンツは一時停止する。案内が確実に聞こえたうえで、ユーザーの再生状態を必要以上に壊さない
- ❌ 端末のシステム音量が絞られていれば案内も小さい。FR-13 の文字どおりの要件は満たさない
- 判定: **採用**

#### 選択肢 2-C: `.playback` 単独 (nonmixable) で他アプリの音を完全に停止させる

- ✅ 案内が他の音に埋もれる余地が最も小さい
- ❌ 停止した他アプリの再生は自動では戻らず、ユーザーの音楽体験を一方的に破壊する。`.duckOthers` との差は「聞こえやすさ」ではなく「相手を止めるか下げるか」でしかなく、案内の可聴性という目的に対して代償が釣り合わない
- 判定: 棄却 (実地検証で `.duckOthers` では案内が埋もれると分かった場合に再検討する)

#### 選択肢 2-D: `MPVolumeView` の内部スライダー経由でシステム音量を最大に上書きする

- ✅ FR-13 を文字どおり満たせる (ように見える)
- ❌ `outputVolume` のドキュメントが「Only the user can directly set the system volume」と明示しており、**公式に想定された使い方ではない**。`MPVolumeView` は「ユーザーに音量調整の UI を提供する」ためのビューであり、その内部構造 (サブビューの `UISlider`) に依存して値を書き換えるのは実装詳細への依存で、OS 更新で無言に壊れる
- ❌ ユーザーが意図的に下げた音量をアプリが勝手に最大化する挙動は、App Store 審査上のリスクがある (requirements.md §8 が「App Store 審査 (災害系アプリの表現規制)」を既にリスクとして挙げている領域と地続き)
- ❌ 壊れ方が「案内が鳴らない・小さい」という**発災時にしか露見しない**形になる。テストで守れない依存を避難経路上に置くべきではない
- 判定: 棄却

## 決定

**論点 1 は選択肢 1-A、論点 2 は選択肢 2-B を採用する。**

### 案内文生成 (ドメイン層)

`app/TendenkoDomain/Sources/TendenkoDomain/GuidanceScript.swift` に純粋関数として置く。`Route` のノード列を辿り、隣接エッジの `bearingDeg` の差から曲がる方向を、`grade` から坂を、`EdgeFlags.steps` から階段を判定して、発話地点 (`nodeID`) つきの指示列を返す。

**発話粒度は「曲がり角・坂・階段・到達でのみ発話し、直進中は黙る」とする。** FR-13 の「画面を見ずに完走できる粒度」は、情報量を増やすことではなく、次の行動が変わる地点だけを言うことで達成される。直進が続く区間は発話せず、次の指示までの距離に畳んで「300 メートル直進して、次の角を右」の形にする。

判定の閾値 (緩い曲がり/曲がり/U ターンの角度、坂とみなす勾配、距離の丸め単位) は `CostModel` (`EvacuationRouter.swift`) が探索の重みを値で持つのと同じ流儀で `GuidanceStyle` 構造体に切り出し、実データを見ながら調整できるようにする。**`CostModel.turnThresholdDeg` は流用しない** — 探索における「曲がりにくさのペナルティをかけるか」と、案内における「曲がったと言うべきか」は別の問題であり、片方の調整がもう片方に漏れる結合を作らない。

### 音声セッション (UI 層)

`app/Tendenko/SpeechAnnouncer.swift` で `AVAudioSession` を `.playback` / mode `.voicePrompt` / options `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]` に設定し、`AVSpeechSynthesizer` で読み上げる。`AVSpeechUtterance.volume` は 1.0 (セッション内の最大) とする。

セッションの設定や発話に失敗しても**地図表示は継続する** (縮退)。`MBTilesServer` / `GlyphServer` の失敗時に地図を出し続ける既存の方針 (`ContentView.startGlyphServer()`) と揃える。音が出ないことは案内の劣化だが、画面まで落とす理由にはならない。

### FR-13 の要件変更

**「音量は端末設定に関わらず最大で再生する」は達成不可能であることが確定したため、要件を「サイレントスイッチ・画面ロック状態でも再生し、アプリ内の再生音量は最大とする。システム音量はユーザーの設定に従う」に緩和する。** 黙って未達にせず、requirements.md の FR-13 に注記を入れて根拠 (本 ADR) を参照させる。

この緩和は本アプリの位置づけと整合している。requirements.md §3.3 が明記するとおり、tendenko は「公式警報の後追いで自動的に避難準備を整える係」であり、一次警報手段 (ETWS) の代替ではない。端末を消音にしているユーザーへの最初の到達手段は ETWS であって本アプリではない。

## 帰結

- `TendenkoDomain` に `GuidanceScript.swift` が追加され、`make domain-test` の対象になる。FR-14 (逸脱リルート)・FR-16 (到達検知) は、この指示列の `nodeID` に現在地を突き合わせる形で次タスクとして実装できる
- UI 層に `AVFoundation` 依存が入る。ドメイン層には入れない
- **バックグラウンド (画面ロック中) の発話継続には `UIBackgroundModes` の `audio` が必要**。FR-10 (EEW プッシュでバックグラウンド起動) と組み合わせる段階で `app/project.yml` への追加要否を判断する。今回のスコープ (フォアグラウンドで経路確定時に発話) では追加しない
- `.duckOthers` で案内が他の音に埋もれるかは、シミュレータでの音楽再生との併用と、可能なら実機で確認する。埋もれると判明した場合は選択肢 2-C を再検討する
- 日本語文言のハードコードは MVP のスコープ (国内限定、requirements.md §2.1 の対応エリア「全国」) を根拠に許容する。**海外対応を検討する段階になったら**、`Maneuver` (構造) と文言生成を分離して再検討する
- 未解決: 到達予想時刻の音声反映 (FR-17、VTSE51) は `server/` の電文解析が前提のため未着手。`GuidanceScript` の指示列とは独立した発話として後から重ねられる想定

## 追記 (2026-08-02): 実装で判明した「曲がる案内は分岐点でだけ出す」

同日中に実装した。合成グラフの単体テストはすべて通ったが、**釜石メッシュ (584177) の実データを流したところ案内が使い物にならなかった**ため、判定を 1 つ足している。

### 起きたこと

5,479m の経路に対して案内が **約 90 件**生成され、その大半が「やや右に進みます」「やや左に進みます」の交互の羅列だった。FR-13 の「画面を見ずに完走できる粒度」とは正反対で、聞き続けられない。

原因は、OSM の道路が**ポリライン**であること。まっすぐな道でも構成ノードごとに方位が数十度単位で揺れるため、ノード間の方位差だけを見ると「曲がった」と判定され続ける。合成グラフのテストは 1 ノードに 1 つの角を置いた理想形だったので、この性質を再現できていなかった。

### 足した判定

**曲がる案内は分岐点 (隣接ノードが 3 つ以上) でのみ出す** (`GuidanceStyle.junctionDegree = 3`)。次数 2 のノードは道の途中で、ユーザーに進む先の選択肢が無い。そこで方向を指示しても行動は変わらず、ノイズにしかならない。

実データでの効果 (経路 288 ノード):

| | 件数 |
|---|---|
| 経路上のノード | 288 (次数 2 が 284、次数 3 が 3、次数 4 が 1) |
| 案内件数 | 約 90 件 → **3 件** |
| 意図的に黙らせた「非分岐点での 50 度超の屈曲」 | 11 箇所 |

最後の行は正直に記録しておく。**急な屈曲でも分岐点でなければ何も言わない**という選択をしている。道なりに進むしかない地点なので判断は変わらないという理由だが、見通しの悪い屈曲で不安になる可能性は残る。訓練モード (FR-07) の実地検証で問題が出たら再検討する。

階段 (`.steps`) と坂 (`.climb`) には分岐点の条件を課さない。これらは「どちらへ行くか」ではなく足元・体力の話で、選択の余地とは無関係だから。

### `TurnDirection.uTurn` を `sharpLeft` / `sharpRight` に置き換えた

実データで「3000メートル進んで、後ろへ引き返します」という案内が出た。しかし `EvacuationRouter` は来た道への即折り返しを展開しない (`if e.to == s.key.from { continue }`) ため、**180 度近い転換は必ず別の道への折り返し = 九十九折り (ヘアピン)** である。高台へ登る経路ではむしろ正常な形で、「引き返す」は誤った案内だった。

方向を保った `sharpLeft` / `sharpRight` に置き換え、文言を「折り返すように左へ進みます」に改めた。

### 残る課題

- 実データの経路では **3,000m・1,950m の無案内区間**が生じている。分岐点が 5.5km に 4 箇所しかない山道なので判定としては正しいが、長時間何も言わないのは不安を招く。区間途中での進捗案内 (「あと◯メートルです」) は現在地への追従が要るため、FR-14 (逸脱リルート)・FR-16 (到達検知) と合わせて実装する
- 都市部 (格子状の街路で分岐点が密) では逆に案内過多になる可能性がある。ADR-0006 のラベル過密と同じ論点で、都市部メッシュの実データでの確認は未着手

## 追記 (2026-08-02): 聴取して分かった不自然さの調整

シミュレータで実際に聞いたところ不自然だという指摘を受け、4 点を切り分けた。うち 3 点はコードで直し、1 点は直せないことが分かった。

### 直したもの

**1. 語順を「距離 → 動作」にした (カーナビ準拠)**

「300メートル進んで、次の角を右です」→「300メートル先、右に曲がります」。先に距離を言うほうが身構えられる。「やや右に進みます」→「右方向です」のように、実際のナビで使われる短い言い回しに揃えた。

**2. 1km 以上はキロで読む**

「3000メートル」は数字が大きすぎて耳で距離感に変換できない。`GuidanceStyle.kilometerThresholdM = 1000` を境に 0.1km 単位で読む (小数点以下が 0 なら整数)。釜石の実データでの変化:

| | 変更前 | 変更後 |
|---|---|---|
| 概要 | 東前樋が沢へ、およそ5500メートルです | 東前樋が沢へ、およそ**5.5キロ**です |
| 折り返し | 3000メートル進んで、折り返すように左へ進みます | **3キロ先**、折り返すように左です |
| 到着 | 1950メートル先、東前樋が沢に到着します | **2キロ先**、東前樋が沢に到着します |

**3. 速度・間・音声品質**

- `rate` を既定 (`AVSpeechUtteranceDefaultSpeechRate` = 0.5) の 0.9 倍。歩きながら聞くには既定はやや速い。落としすぎると間延びしてかえって聞き取りにくいので 1 割程度に留めた
- `postUtteranceDelay = 0.4`。指示を続けて流すと 1 文に聞こえて切れ目が分からない
- `AVSpeechSynthesisVoice.speechVoices()` から premium > enhanced > default の順に最良の日本語音声を選ぶ。`AVSpeechSynthesisVoice(language:)` は既定 (compact) しか返さない

### 直せないもの: 固有名詞の読み

「東前樋が沢」「鵜住居小学校・釜石東中学校校庭」のような避難場所名を TTS が正しく読む保証はない。**`region.sqlite` の `shelters` テーブルは `id, name, lat, lon, elev_m` のみで読み仮名を持たない**ため、アプリ側では対処できない。

対処するなら国土地理院の指定緊急避難場所データにふりがな列があるかを確認し、あれば [ADR-0003](0003-region-package-format.md) のスキーマに `name_kana` を追加して pipeline とアプリの両方を直す必要がある (`AVSpeechSynthesisIPANotationAttribute` で読みを与えられる)。元データがローカルに無く未確認。**未着手**。

### 声質の評価はシミュレータではできない — 実測で確定

シミュレータのログには `Error fetching voices: DecodingError.dataCorrupted ... Using fallback voices` が出ており、音声データ自体が揃っていない。どこまでが実装由来かを切り分けるため、シミュレータ上で `AVSpeechSynthesisVoice.speechVoices()` を実際に列挙した。

```
全音声数: 68
ja-JP 音声数: 1
  Kyoko | com.apple.voice.super-compact.ja-JP.Kyoko | quality=default
AVSpeechSynthesisVoice(language: "ja-JP") => 同じ Kyoko
```

**シミュレータには `super-compact` の Kyoko が 1 つだけ**入っている。`super-compact` は Apple の音声バリアントの中で最も小さく品質が低いもので、「発音が不自然」という印象はこれで説明がつく。

この実測で 3 点が確定した。

- **英語音声で日本語を読んでいるわけではない**。`AVSpeechSynthesisVoice(language:)` は正しく ja-JP の音声を返しており、実装の不具合ではない
- **本 ADR で決めた「premium > enhanced > default から最良を選ぶ」は正しく動くが、シミュレータでは選択肢が 1 つしかないため効果が出ない**
- **実機では改善する見込み**。実機の内蔵音声は通常 `compact` (super-compact より上位) で、ユーザーが「設定 > アクセシビリティ > 読み上げコンテンツ > 声」から `enhanced`/`premium` を追加すればさらに良くなる。実装はあれば自動で選ぶ

**結論: 声質・発音についてコード側で追加でできることはない。評価は実機で行う。** 速度 (`rate`) と間 (`postUtteranceDelay`) の調整は両環境で効く。
