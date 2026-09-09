# ADR-0008: 連続測位は案内フェーズの間だけ有効にし、平時は significant location change に留める

- ステータス: Accepted
- 日付: 2026-09-08
- プロジェクト: tendenko

## コンテキスト

FR-14 は「経路逸脱を検知したら **3 秒以内に**リルートし音声で通知する」と規定する。FR-16 は目的地到達の検知を求める。判定そのものは [ADR-0007](0007-voice-guidance.md) の方針どおりドメイン層に純粋関数として実装済みで、`RouteTracking.swift` の `RouteTracker.track` が現在地を受け取って逸脱・到達・案内の進行・次の指示までの残距離を返す。

**足りないのは入力側、すなわち現在地の供給頻度である。**

現状の `RegionCacheCoordinator` (UI 層) が使っている測位は 2 つだけで、どちらも FR-14 の 3 秒に届かない。

| 手段 | 用途 | 配信頻度 |
|---|---|---|
| `CLLocationManager.requestLocation()` | 起動時の単発測位 (FR-02 のメッシュ判定と経路の始点) | 1 回のみ |
| `startMonitoringSignificantLocationChanges()` | 移動先パッケージの先読み (FR-03) | 数百 m〜数 km 移動時、または数分間隔 |

significant location change は基地局・Wi-Fi の変化を基準にした省電力サービスで、Apple も配信間隔を保証していない。実測でも数百 m 級の移動が必要で、これを逸脱検知に使えば「経路を外れてから通知まで数分」になる。**逸脱の 3 秒判定には `startUpdatingLocation()` による連続測位が要る。**

一方で NFR-05 は次のように定めている。

| ID | 項目 | 目標 |
|---|---|---|
| NFR-05 | バッテリー | 平時の常駐消費は 1 日 2% 未満 (significant location change ベース、**常時 GPS 禁止**) |

連続測位と NFR-05 は、そのままでは正面から衝突する。この衝突をどう解くかを決める必要がある。

### 「平時」と「案内フェーズ」は別の区間である

requirements.md §3.1 の段階起動モデルは、アプリの生涯を平時 (`idle`) / ウォームアップ (`warmup`) / 案内 (`guidance`) / 終了 (`finished`) に分けている (`EvacuationPhase` としてドメイン層に実装済み)。NFR-05 が制約しているのは表の文言どおり「**平時**の常駐消費」であり、案内フェーズの消費ではない。

案内フェーズは性質がまるで違う。

- **有限である。** 徒歩での避難は数分〜数十分で終わり、`RouteTracker` が到達を検知した時点 (FR-16) で終わる
- **そのために電池を使う区間である。** 津波警報下で「電池を節約したので逸脱に気付けませんでした」は、プロダクトの目的 (T3 = 移動時間の短縮) を放棄している
- **ユーザーが画面を開いている。** FR-11 は「通知タップまたはアプリ起動の瞬間に、経路 1 本が地図に表示され音声が流れている状態」を求めており、案内フェーズはフォアグラウンドで始まる

つまり NFR-05 は「連続測位を一切するな」ではなく「**平時に**常駐して GPS を焚き続けるな」と読むのが要件の意図に合う。問題は、その読みを実装上どう保証するかである。

## 検討した選択肢

### 選択肢 A: 常に `startUpdatingLocation()` を使う

起動時から連続測位に切り替え、FR-02 のメッシュ判定も FR-14 の逸脱判定も同じ供給元で賄う。

- ✅ 実装が単純。測位の系統が 1 つで済み、フェーズ遷移の取りこぼしという失敗モードが無い
- ✅ 案内の開始判定が遅れても、既に高頻度の現在地が手元にある
- ❌ **NFR-05 に正面から違反する。** アプリを一度起動したら以後 GPS が焚かれ続け、「平時の常駐消費 1 日 2% 未満」は成立しない
- ❌ 平時に高頻度の位置を取得する必然性が無い。FR-02/FR-03 のローリングキャッシュはメッシュ (約 10km 四方) 単位の判断で、10m 級の精度も 1Hz の頻度も要らない
- ❌ 位置情報の取得量を必要最小限に留めるという原則 (App Store のプライバシー要件でも問われる) から外れる
- 判定: 棄却

### 選択肢 B: significant location change の精度・頻度を上げて流用する

- ✅ 系統が増えない
- ❌ **できない。** significant location change に精度や頻度のパラメータは無い (`desiredAccuracy` / `distanceFilter` は `startUpdatingLocation` にしか効かない)。API の性質上、選択肢として成立しない
- 判定: 棄却 (実現不能)

### 選択肢 C: 案内フェーズの間だけ `startUpdatingLocation()` に切り替える

平時は現状 (`requestLocation` の単発 + significant location change) のまま。経路が確定して案内が始まった時点で連続測位を追加し、到達・解除・フォアグラウンド離脱で止める。

- ✅ NFR-05 の「平時」の定義を実装上の状態として明示でき、要件と実装が 1 対 1 で対応する
- ✅ 連続測位の生存区間が「案内中かつフォアグラウンド」に閉じ、止め忘れの経路が構造的に少ない
- ✅ FR-14 の 3 秒判定に必要な頻度 (`distanceFilter` なし・`desiredAccuracy` = best) を、必要な区間だけで得られる
- ❌ 系統が 2 つになり、フェーズの開始・終了で切り替える配線が増える。切り替えを取りこぼすと「案内中なのに追従しない」または「平時に GPS が焚かれ続ける」という、どちらも発災時にしか露見しない壊れ方をする
- ❌ 案内フェーズの開始判定そのものが必要になる (後述)
- 判定: **採用**

### 選択肢 D: 案内フェーズ中は `CLLocationUpdate.liveUpdates` (iOS 17+) を使う

- ✅ async シーケンスで受け取れ、`CLLocationManagerDelegate` の nonisolated ホップが不要になる
- ❌ 既存の測位はすべて `CLLocationManager` のデリゲート経由で `RegionCacheCoordinator` に集約されている。案内フェーズだけ別 API にすると、同じ「現在地」の供給元が 2 種類のフレームワーク経路に分かれる。精度・古さのフィルタ (`routeOriginAccuracyM` / `routeOriginMaxAge`) を二重に実装することになる
- ❌ 得られるのは書き味の改善だけで、電池・精度・頻度のいずれも選択肢 C と変わらない
- 判定: 棄却 (デリゲート経路を一本化する価値のほうが大きい。将来 `CLLocationManager` 側を畳むなら全体を移す)

## 決定

**選択肢 C を採用する。**

### 案内フェーズの境界

案内フェーズの起点は本来 VTSE41 (津波警報・注意報) の受信だが、電文受信 (FR-10 / FR-11 のプッシュ) は未実装である。そこで当面は **「実データの経路が確定し、音声案内を開始した時点」を案内フェーズの開始とみなす**。これは現在 `ContentView` が読み上げを始める条件 (`SampleFallback.shouldAnnounce`) と同じ境界であり、新しい判断を持ち込まない。

- FR-11 は「アプリ起動の瞬間に経路が表示され音声が流れている」ことを求めており、起動＝案内開始は要件と整合する。発災時の操作ゼロ原則 (requirements.md §1) から、案内開始にユーザー操作を要求しない
- **同梱サンプル (釜石 584177) へのフォールバック中は案内フェーズに入らない。** サンプルの経路は現在地と無関係で追従する意味が無く、[ADR-0004 追記](0004-region-package-delivery.md) の「サンプル表示中は読み上げない」と同じ境界に揃える

終了条件は 3 つ。いずれか 1 つで連続測位を止める。

| 終了条件 | 根拠 |
|---|---|
| 目的地への到達 (`TrackingState.hasArrived`) | FR-16。到達後の追従は電池を使うだけで案内を生まない |
| アプリがフォアグラウンドを離れる (`ScenePhase != .active`) | 後述のとおり背景測位を今回は有効化しないため、続けても更新が届かない |
| 経路・地域パッケージの差し替え | 追従対象が無くなる。新しい経路が確定したら改めて開始する |

### 測位の構成

案内フェーズ中の `CLLocationManager` は次のとおり設定する。

| 設定 | 値 | 理由 |
|---|---|---|
| `desiredAccuracy` | `kCLLocationAccuracyBest` | 逸脱の許容幅は `TrackingStyle.offRouteToleranceM = 40m`。測位誤差がこれに迫ると誤リルートを繰り返す |
| `distanceFilter` | `kCLDistanceFilterNone` | FR-14 の 3 秒判定。距離で間引くと停止中・低速時に更新が止まる |
| `activityType` | `.fitness` | 徒歩の避難。Apple の分類で歩行・走行を含むのはこれ |
| `pausesLocationUpdatesAutomatically` | `false` | **既定 (`true`) のままだと、OS が「移動が止まった」と判断した時点で更新を止める。**避難中に無言で追従が死ぬ壊れ方を許容できない |
| `allowsBackgroundLocationUpdates` | 設定しない (既定 `false`) | 後述 |

`kCLLocationAccuracyBestForNavigation` は採らない。Apple は車載ナビ向けと位置づけており、徒歩速度に対しては電池を余分に使うだけで精度の実益が無い。

平時側の設定 (`kCLLocationAccuracyNearestTenMeters` + `requestLocation` + significant location change) は**変更しない**。案内フェーズを抜けたら平時の設定に戻す。

### バックグラウンドの扱い — 今回は有効化しない

`allowsBackgroundLocationUpdates = true` には `UIBackgroundModes` の `location` と Always 権限が要る。FR-01 は Always 権限の取得を掲げているが、現在の `project.yml` は `NSLocationWhenInUseUsageDescription` のみで、Always も背景モードも宣言していない。

**今回は追加しない。** 背景測位は FR-10 (EEW プッシュでバックグラウンド起動) と一体で設計すべき論点で、ADR-0007 が `UIBackgroundModes` の `audio` について同じ判断 (「FR-10 と組み合わせる段階で判断する」) を既に下している。音声と測位の背景継続は同じプッシュ起動の文脈で一度に決めるほうが、権限の要求文言もユーザーへの説明も一貫する。それまで案内フェーズはフォアグラウンドに閉じる。

### MapLibre の現在地表示は案内フェーズ中だけ有効にする

案内中の地図に現在地が出ないと、音声を聞き逃したときに自分の位置を確かめる手段が無い。`MLNMapView.showsUserLocation` で表示する。

ただし **`MLNMapView` は自前の `CLLocationManager` を内部に持ち、`showsUserLocation = true` の間それを回す。** つまり測位の系統がもう 1 つ増える。これを常時有効にすると、`RegionCacheCoordinator` 側を案内フェーズに絞った意味が消える。したがって `showsUserLocation` も**案内フェーズと同じ区間でのみ有効にする**。二重に測位が走ることは受け入れる — MapLibre の内部マネージャに外から現在地を注入する公開 API が無く、表示を自前のアノテーションで実装するとヘディング表示・精度円を作り直すことになるため、区間を揃えることで折り合いをつける。

## 帰結

- `RegionCacheCoordinator` に案内フェーズの開始・終了 (`beginGuidance()` / `endGuidance()`) が加わり、連続測位の生存区間を持つ。平時の挙動は変わらない
- 連続測位中は現在地が 1Hz 級で届くため、**現在地が届くたびに経路を引き直す現在の `ContentView` の配線 (`onChange(of: coordinator.currentLocation)` → `computeOverlay()`) は成立しなくなる。**経路の再計算は「地域パッケージの切り替え」と「逸脱によるリルート」に限定し、通常の位置更新は追従 (`RouteTracker`) にだけ流す
- 同じ理由で、`RegionCacheCoordinator.handle()` が位置更新のたびに `refreshManifest()` を呼ぶ経路も 1Hz で走ってはいけない。案内フェーズ中の位置更新はパッケージ取得の起点にしない
- リルートを 3 秒以内に返すには、リルートのたびに `region.sqlite` から `RoadGraph` を読み直すのでは間に合わない可能性がある。読み込み済みのグラフを保持する層 (`RouteEngine`) を UI 層に置く
- **電池実測は未実施。** 案内フェーズ中の消費は NFR-05 の対象外だが、フェーズを正しく抜けているか (平時に連続測位が残っていないか) は実機で確認する必要がある。確認方法は Xcode の Energy Log と、設定 > プライバシー > 位置情報サービスの矢印表示
- **見直しの条件**: FR-10 (EEW プッシュでのバックグラウンド起動) を実装する段階で、Always 権限・`UIBackgroundModes` の `location` と `audio`・背景での案内継続をまとめて再検討する。本 ADR の「フォアグラウンドに閉じる」判断はそこで置き換わる
- **見直しの条件**: 電文受信 (#24) が実装されたら、案内フェーズの起点を「経路確定」から `EvacuationPhase` の `guidance` 遷移に移す。本 ADR の境界は、それまでの暫定である
