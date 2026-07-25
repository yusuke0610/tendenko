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

公開読み取り専用バケット直下に置く (バケット名・アクセス制御は infra セッションで確定):

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
