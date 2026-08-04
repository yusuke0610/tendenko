# ADR-0004: 地域パッケージを GCS の manifest 経由で配信し、端末は 2 次メッシュ単位のローリングキャッシュで保持する

- ステータス: Accepted
- 日付: 2026-07-25
- プロジェクト: tendenko

## コンテキスト

[ADR-0003](0003-region-package-format.md) で地域パッケージのフォーマット (`region-<mesh>.sqlite` + `tiles-<mesh>.mbtiles`、2 次メッシュ単位) と manifest (JSON) を GCS に置く方針までは決めたが、**「manifest と GCS レイアウトの設計」「端末側の取得・キャッシュ機構」は未決のまま**残っていた (ADR-0003「正直な弱点」)。現状:

- パイプラインは全国 2,515 パッケージ + `manifest.json` をローカル生成済みだが、**GCS アップロードは未実装** (`build-package/main.go` のコメントのみ)。`infra/` はバケットの OpenTofu 定義未作成
- アプリ (`ContentView`) は開発用に釜石メッシュ (584177) の MBTiles を**直接同梱**して表示しているだけ。`GraphLoader` / `EvacuationRouter` は実装済みだが UI 未接続。メッシュ計算もダウンロード層も Swift 側に存在しない

この ADR は **FR-02 (地域パッケージの自動ダウンロード) の配信経路・キャッシュ機構・レイヤ帰属**を決める。前提となる要件:

- FR-02/03: ローリングキャッシュ — 現在地周辺の自動 DL と、significant location change での移動先先読み
- FR-05: 登録地点周辺も常時保持
- FR-06 / 要件§8: 差分 DL と「生成から 6 ヶ月超は警告」
- FR-15: 詳細データ未取得地域は縮退モード (コンパス案内) で成立する
- NFR-04: 1 地域パッケージ < 150MB / 同梱最小データセット < 50MB
- CLAUDE.md: **app にサーバー・インフラ依存を持ち込まない**。**ドメイン層は純粋関数 + TDD**

## 決定

### 1. GCS レイアウトと manifest

配信バケット直下に置く (バケット名・アクセス制御は infra セッションで確定。アクセス範囲は後述の「追記 (2026-07-25): バケットは当面非公開」で private に決着):

```
<bucket>/
  manifest.json                     # 全パッケージの索引 (schema_version, generated_at, packages[])
  packages/region-<mesh>.sqlite      # 道路グラフ (ADR-0003 スキーマ)
  packages/tiles-<mesh>.mbtiles      # ベクタタイル
```

- manifest は既存の `schema_version: 1` を踏襲。各 package に `mesh` / `file` / `bytes` / `sha256` / `tiles_file` / `tiles_bytes` / `tiles_sha256` を持つ。端末はこれで差分 DL (FR-06)・整合性検証・鮮度警告 (FR-06 の 6 ヶ月判定は `generated_at`) を行う
- **端末はまず manifest だけを取得**し、必要メッシュのエントリを引いて個別パッケージを DL する。パッケージ本体は不変 (内容が変われば別 mesh ではなくハッシュが変わる) なので、`sha256` 一致でキャッシュ有効と判定できる
- パイプライン側の GCS アップロードと差分判定 (`gsutil rsync` 相当) は**別作業**。この ADR ではアプリが読む契約 (レイアウト + manifest スキーマ) のみ固定する

### 2. レイヤ帰属 (CLAUDE.md の境界を守る 3 層)

| 責務 | 置き場所 | 純粋性 |
|---|---|---|
| メッシュ計算 (緯度経度→2 次メッシュ、3×3 近傍列挙) | `TendenkoDomain/MeshCode` | **純粋・TDD**。Go の `pipeline/internal/mesh` と同一アルゴリズムを移植し、既知コードで一致を検証 |
| キャッシュ計画 (どのメッシュを保持し、どれを退避するか) | `TendenkoDomain/CachePlan` | **純粋関数**。現在地 + 登録地点の 3×3 を desired set とし、予算超過分を LRU で退避する「計画」を返す。I/O はしない |
| 取得・保存・整合性 (manifest 取得、DL、sha256 検証、原子的リネーム、キャッシュディレクトリ管理) | `TendenkoStorage/RegionPackageStore` | 副作用あり。GRDB / ネットワークと同じくここに隔離 |

- ダウンロード元は `PackageFetcher` プロトコルで抽象化し、`RegionPackageStore` はそれに依存する。本番は GCS を叩く HTTP 実装、テストは fake 実装を注入する → **GCS バケット未構築でもアプリ側を TDD で先行実装できる**
- **CLAUDE.md の「app にインフラ依存を持ち込まない」の解釈**: GCS の URL 構築やバケット名という*インフラの形*は `PackageFetcher` の本番実装 (app ターゲット側) に閉じ込め、ドメイン層とストア層のロジックには漏らさない

### 3. ローリングキャッシュ方針

- **desired set** = 現在地メッシュの 3×3 (9) ∪ 各登録地点 (FR-05) の 3×3。ADR-0003 の「現在地 + 周囲 8」を踏襲
- **退避**: LRU。キャッシュ予算 (パッケージ数 or 合計バイト。初期値は実装時に決め、NFR-04 と端末容量から調整) を超えたら、desired set に**含まれない**もっとも古いメッシュから削除する。desired set は退避しない
- **トリガ**: significant location change (FR-03) で現在地メッシュが変わったら desired set を再計算し、不足分を DL・余剰を退避。CLLocationManager の監視は app ターゲットの責務で、`CachePlan` に現在地メッシュ + 登録地点を渡すだけ
- **整合性・原子性**: temp ファイルに DL → manifest の sha256 検証 → 検証通過後に原子的リネームでキャッシュ投入。既存かつハッシュ一致なら DL をスキップ (冪等)。検証失敗はそのパッケージを不在として扱う
- **縮退モード連携 (FR-15)**: ストアは「このメッシュのパッケージを持っているか」を返すだけで、地図・経路をブロックしない。未取得メッシュは縮退 (コンパス) に落ちる

## 検討した選択肢

### 配信経路

**GCS + 静的 manifest (採用)** — ✅ サーバーレスで運用コストゼロに近い。パッケージは不変オブジェクトで CDN キャッシュと相性が良い。差分 DL は manifest 突き合わせだけで済む。❌ 差分の粒度がパッケージ単位 (パッケージ内部の部分更新はできない) だが、2 次メッシュは元々十分小さく問題にならない。

**API サーバー経由で配信** — ✅ 認証・レート制御・動的な絞り込みが柔軟。❌ subscriber/fanout に配信責務が乗り、常時起動コストと単一障害点が増える。津波後の避難という用途で、静的ファイル配信に動的サーバーを挟む必然性がない。**棄却**

### メッシュ計算の置き場所

**ドメイン層に純粋実装 (採用)** — ✅ Go 側と同一アルゴリズムを Swift で持ち、既知コードで一致検証できる。シミュレータ不要で `make domain-test` に乗る。❌ Go と Swift で二重実装になるが、緯度経度↔メッシュ変換は JIS X 0410 の固定式で変化しないため保守負担は小さい。

**iOS の位置情報 API 側に埋め込む** — ❌ 純粋ロジックが副作用層に混ざり TDD できない。CLAUDE.md のドメイン層方針に反する。**棄却**

## 正直な弱点

- **キャッシュ予算の具体値が未定**。パッケージ数上限にするか合計バイト上限にするか、初期値をいくつにするかは、実機での DL 時間・ストレージ実測を見て決める (実装時にベンチ)。設計上は `CachePlan` の引数として外出しし、値の変更がロジックに波及しないようにする
- **significant location change の粒度と DL のタイミング**は実機依存。バックグラウンド DL の iOS 制約 (BGTaskScheduler 等) はこの ADR の範囲外で、app 実装時に別途詰める
- **manifest の全国版は約 564KB** (2,515 エントリ)。毎起動で全取得しても許容範囲だが、肥大化するなら 1 次メッシュ単位の分割 manifest を将来検討する
- パイプラインの GCS アップロードと infra のバケット構築が未着手のため、**本番 end-to-end はこの ADR だけでは完成しない**。アプリ側は fake fetcher で先行実装し、実 GCS 接続は後続セッションで繋ぐ

## 帰結

- `TendenkoDomain` に `MeshCode`・`CachePlan` を純粋関数 + TDD で追加する
- `TendenkoStorage` に `PackageFetcher` プロトコルと `RegionPackageStore` を追加する。テストは fake fetcher で回す
- app ターゲットに GCS を叩く `PackageFetcher` 本番実装と、`CLLocationManager` → `CachePlan` → `RegionPackageStore` を繋ぐ位置情報監視を追加する。`ContentView` の同梱データ読み込みを、キャッシュから取得したパッケージの読み込みに置き換える
- パッケージ本体を配る GCS バケットの OpenTofu 定義 (infra/、nixpkgs の `tofu`) と、パイプラインの GCS アップロードは**別セッション**で行う (この ADR がアプリの読む契約を固定するので、独立して進められる)
- **再検討条件**: 実機でキャッシュ予算・DL 時間が要件に合わなければ desired set の縮小 (3×3 → 進行方向優先) や予算値を見直す。manifest 肥大が問題化したら分割 manifest を導入する

## 追記 (2026-07-25): パイプラインの GCS アップロードと manifest への tiles_sha256 追加

配信の書き手側 (パイプライン) を実装した。

- `pipeline/internal/publish`: 生成済みの `out/` を GCS へ上げる。`cloud.google.com/go/storage` を使い、認証は ADC (Cloud Run jobs の Workload Identity / ローカルの `gcloud auth application-default login`)。オブジェクトレイアウトは決定 §1 のとおり (`manifest.json` はルート、パッケージは `packages/` 配下)。**manifest.json はパッケージ本体を全て上げ終えてから最後に上げる** — クライアントが未アップロードのパッケージを参照する manifest を見ないようにするため。既存オブジェクトと CRC32C が一致するファイルはスキップする (gsutil rsync 相当の差分。GCS が CRC32C を native に持つため md5/sha 再計算より安い)
- `build-package` に `-upload gs://bucket[/prefix]` フラグを追加 (一括モードのみ)。オブジェクトキー写像・gs URL パースは純粋関数として単体テスト済み
- **manifest スキーマに `tiles_sha256` を追加**した。決定 §1 で app 側の検証に必要としながら、パイプラインが tiles のハッシュを記録していなかった (region の sha256 のみ)。`buildOne` で MBTiles 生成時に計算するようにし、app の `RegionPackageStore` が region と同じく tiles も sha256 検証できるようにした。schema_version は 1 のまま (後方互換な追加フィールド)

## 追記 (2026-07-25): 公開 (public) に決定 — 直下の「当面非公開」を supersede

下の「当面非公開」で挙げた前提 ((a)/(b) のいずれかを先に決める) について、**ODbL を整理して public 配信する ((a)) と決定した** ([ADR-0002](0002-oss-licensing.md) データ側 Accepted)。

- **ODbL の帰結**: region.sqlite は OSM の派生データベースであり、share-alike により「**無償で入手可能**」であることが求められる。公開配信がその履行そのものであり、逆に**認証・署名 URL でアクセスを絞る ((b)) と ODbL の anti-TPM 条項と衝突する** (制限のない無償版を別途出す義務が残る)。よって OSM 由来データは public 配信が最も整合的
- **infra**: `google_storage_bucket.packages` を `public_access_prevention = "inherited"` に変更し、`allUsers` に `roles/storage.objectViewer` を付与。app は認証なしの HTTPS (`https://storage.googleapis.com/<bucket>/...`) で取得する (`packages_public_base_url` 出力を参照)。`tofu fmt` / `validate` 済み
- **公開再生成の前提 (ブロッカー)**: (1) 公開パッケージに **OSM 帰属表示**をアプリで出す (FR-02 app 配線)、(2) **A40 条件付き県の由来フラグを公開パッケージから除外**する (県別精査は未完、ADR-0002)。この 2 つが済むまで実データの public 再アップロードはしない
- 下の「当面非公開」の節は**この決定により無効**。infra の private 設定 (enforced) はこの追記の public 設定に置き換え済み

## 追記 (2026-07-25): バケットは当面非公開 (private) にする 〔SUPERSEDED — 上の公開決定に置き換え〕

決定 §1 では「公開読み取り専用バケット」と書いたが、infra 実装時に **当面は private に倒す**判断をした。

- **理由**: 配信物は OSM 由来の道路グラフ (region.sqlite) を含み、**ODbL share-alike 義務の整理が [ADR-0002](0002-oss-licensing.md) / [docs/licenses.md](../licenses.md) で未決のまま残っている** (ADR-0003 の「正直な弱点」でも既知)。バケットを world-public (allUsers:objectViewer) にすることは「公開配布」に相当し、その未解決の義務を発火させる。ライセンス整理より先に技術都合で公開してしまうのを避ける
- **決定**: `infra/` の `google_storage_bucket.packages` は `public_access_prevention = "enforced"` + `uniform_bucket_level_access = true` で作り、allUsers を付けない。パイプラインは自分の SA 権限 (`roles/storage.objectAdmin`) でアップロードできる。app からの取得 (認証なしの URLSession) はこの制約を解除してから繋ぐ
- **帰結**: FR-02 の app 配線 (Task) は、(a) ODbL 整理を済ませて world-public 化する、または (b) 署名付き URL / 認証付き取得にする、のいずれかを先に決める必要がある。この選択は app 実装セッションで扱う。infra はローカル state で bootstrap し、`tofu init` / `validate` まで通ることを確認済み (`plan`/`apply` は project_id と認証が必要)

## 追記 (2026-08-02): 測位はパッケージ取得の可否と切り離す

FR-02 の app 配線 (`RegionCacheCoordinator`) は、測位開始を配信 URL の設定有無で塞いでいた。

```swift
func start() {
    guard store != nil else {              // AppConfig.packagesBaseURL == nil → store == nil
        status = .degraded("配信URLが未設定です")
        return                             // ← 測位に到達しない
    }
    locationManager.requestWhenInUseAuthorization()
    ...
}
```

`AppConfig.packagesBaseURL` は上記ブロッカーが解けるまで `nil` のままなので、**アプリは実際には一度も測位していなかった**。位置情報の許可ダイアログすら出ず、`currentMesh` は nil のまま、経路の始点は `ContentView` の固定値 (釜石 39.29/141.94) が使われ続けていた。実機で確認するまで気づけない種類の不具合で、ログにも痕跡が残らない (CLLocationManager が一切呼ばれないため)。

### 決定

**測位はダウンロードの可否と独立させる。** 配信 URL が未設定でも `start()` は測位を開始し、ダウンロードだけを `store` の有無で分岐する。

理由は、現在地が分からないと FR-15 の縮退モード (「この地域の詳細地図はまだありません」+ コンパス案内) の判定自体が成立しないこと。現在地不明とパッケージ未取得は別の状態であり、後者で前者を代用すると「同梱サンプルの土地にいる」という誤った前提で動く。

あわせて 2 点直した。

- **`desiredAccuracy` を `kCLLocationAccuracyKilometer` → `kCLLocationAccuracyNearestTenMeters`**。メッシュ選択 (約 10km 四方) には 1km 精度で足りるが、経路の始点には粗すぎる。1km ずれた地点から探索すると別の街区から案内が始まる
- **測位の精度と鮮度を検証してから経路の始点に使う**。`desiredAccuracy` は要求であって保証ではなく、とくに significant location change の配信は数百 m 級で届く。水平精度 100m 以内かつ 120 秒以内の測位だけを `currentLocation` に採用し、それ以外は捨てる。粗い測位でもメッシュの判定には使えるのでそちらは続行する
- **`startMonitoringSignificantLocationChanges()` は配信 URL があるときだけ登録する**。これは移動先のパッケージを先読みするための常時監視 (FR-03) で、先読みする配信先が無い状態では常駐と再起動のコストだけが残る。`requestLocation()` の単発測位と違い**アプリを再起動させうる継続サービス**なので、NFR-05 (平時の常駐消費 1 日 2% 未満) の観点でも縮退時は登録しない
- **非同期の取得完了は測位のリビジョンで照合する**。ダウンロード中に次の測位が届いていた場合、完了した古いメッシュのパッケージを公開すると地図と経路が現在地とずれたまま確定する。`ContentView` 側も経路計算の結果を書き戻す前に現在地とパッケージが変わっていないか確かめる
- **`currentLocation` (実測値) を `currentMesh` と別に持つ**。従来 `ContentView.startPoint()` は `mesh.bbox.center` を返しており、これは 2 次メッシュ (約 10km 四方) の中心なので、測位できていても最大 7km ずれた始点で経路を引くことになっていた

### 正直な弱点

**現在地を経路の始点に使うのは、その現在地を含む地域パッケージを読み込めているときだけ**とした。同梱サンプル (釜石) にフォールバックしている状態で実際の現在地から探索すると、`RouteGeometry.nearestNode` が釜石グラフ上のどこかに丸め、まったく無関係な経路を返すため。

つまり配信 URL 未設定の間は、測位はするが経路は依然サンプルの土地のものになる。**本来ここは FR-15 の縮退モードに入るべき場面で、それは未実装**。縮退している事実は `StatusBanner` で画面に出すようにしたが、根本解決は FR-15 の実装を待つ。

### 追記 (2026-08-04): サンプル経路は描いても読み上げない

上の「正直な弱点」で「配信 URL 未設定の間は経路がサンプルの土地のものになる」と書いたが、**その経路を音声でも読み上げていた**。レビューでの指摘を受けて止めた。

地図に描くことと読み上げることは危険度が違う。地図は一目でサンプルと分かり無視もできるが、音声は無関係な方向を断定的に指示してしまい、避難時に取り消しが効かない。requirements.md §3.3 のとおり本アプリは公式警報の後追いで避難準備を整える係であり、誤った方向を能動的に告げるのはその位置づけを踏み越える。

- 判断は `app/Tendenko/SampleFallback.swift` に純粋関数として切り出し、`app/TendenkoTests` で回帰テストを置いた (`make app-test`)。`ContentView` (SwiftUI View) の中に埋めるとテストできず、一番落としたくない性質を守れない
- サンプルへのフォールバック自体も `AppConfig.sampleFallbackEnabled` で明示的にした。開発用の機能であることをコード上で宣言し、リリース時に false にする対象をはっきりさせる
- バナーには「表示中の経路はサンプルです。音声案内は行いません」を添える

根本解決は変わらず FR-15 の縮退モード (浸水域の外周方向 + 最寄り避難場所へのコンパス案内) の実装。
