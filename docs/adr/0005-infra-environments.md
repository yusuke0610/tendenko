# ADR-0005: インフラを再利用モジュール + 環境ディレクトリ (staging/production) で分離する

- ステータス: Accepted
- 日付: 2026-07-28
- プロジェクト: tendenko

## コンテキスト

これまで `infra/` は単一ディレクトリのフラットな OpenTofu 定義で、本番想定の 1 環境しか表現していなかった (配信バケット [ADR-0004] + パイプライン実行基盤 [ADR-0001])。

ローンチ前に、実インフラ経路 (Cloud Run job がイメージを実行 → パッケージ生成 → 配信バケットへアップロード → アプリが公開 URL から取得) を本番と隔離して検証したい。そのための**検証環境 (staging)** を IaC 化する必要がある。要件:

- **本番への事故を防ぐ**: 検証環境への `apply` が本番リソースや state に絶対に触れないこと。防災アプリの配信を止めるわけにいかない
- **重複を避ける**: バケット・Cloud Run job・IAM 等の定義を 2 つ手書きコピーしない (ドリフトの温床)
- **環境差分を明示的に**: 検証はスケジュール実行不要 (手動起動)、リソース小さめ等、環境ごとの違いを変数で表現する
- **第三者がデューデリジェンスできる**構成 (CLAUDE.md)

## 検討した選択肢

### A. 再利用モジュール + 環境ディレクトリ (採用)

```
infra/
  modules/tendenko/        # 全リソースを 1 モジュールに集約 (provider/backend は持たない)
  environments/
    production/            # module 呼び出し + provider + backend + tfvars
    staging/
```

- ✅ 環境ごとに **state もディレクトリも物理分離** — staging の `apply` が production に触れる経路が存在しない
- ✅ リソース定義はモジュール 1 箇所。環境差分は変数 (project_id・バケット名・スケジュール有無・公開可否) だけ
- ✅ 業界標準で、レビュー時に「どの環境に何が適用されるか」が一目でわかる
- ❌ 単一ディレクトリよりファイル数が増え、`cd environments/<env>` の一手間がある
- 判定: **採用**。事故防止 (物理分離) とレビュー性が、個人開発の軽微な手間より優先

### B. Terraform workspace (単一ディレクトリ + `tofu workspace`)

- ✅ ファイル移動が最小。state は workspace ごとに分かれる
- ❌ 同一ディレクトリ・同一 state backend を共有するため、**カレント workspace の取り違えで本番に apply する事故が起きやすい**。防災アプリの配信基盤でこのリスクは受容できない
- ❌ 環境差分を `terraform.workspace` の条件分岐で書くと可読性が落ちる
- 判定: 棄却

### C. 環境ごとにフル手書きコピー

- ❌ 定義の重複でドリフトが必然。棄却

## 決定

**選択肢 A を採用する。**

- `infra/modules/tendenko/` に配信バケット・データバケット・Artifact Registry・Cloud Run job・Cloud Scheduler・SA/IAM をすべて集約する。provider と backend はモジュールに置かない (呼び出し側の責務)
- 環境差分は module の入力変数で表現する。主なもの:
  - `packages_public` (bool): 配信バケットを公開読み取りにするか。**production は true** (ODbL の無償入手要件、ADR-0002)。**staging も true** だが別バケット・限定的な検証データのみを置き、検証後に破棄する運用とする
  - `enable_schedule` (bool): Cloud Scheduler を作るか。**production は true** (定期実行)、**staging は false** (手動起動で検証)
  - `pipeline_image` が空ならジョブ自体を作らない (イメージ push 前でも他リソースは apply できる) — 従来どおり
- `infra/environments/production/` と `infra/environments/staging/` はそれぞれ provider・backend・`terraform.tfvars` を持ち、独立した state で `tofu init/plan/apply` する
- **state backend は当面ローカル** (ADR-0004 と同じくチキンエッグ回避)。GCS backend 化は state 用バケットを別途 bootstrap してから別途
- 実行は `make infra-plan ENV=staging` / `make infra-apply ENV=production` で環境を指定する

## 帰結

- 検証は本番と完全に隔離された GCP プロジェクト/バケットで行える。staging の `apply`/`destroy` が本番に影響しない
- リソース定義はモジュール 1 箇所で保守。環境追加は `environments/<env>/` を 1 つ増やして tfvars を書くだけ
- `apply` と実際の検証には GCP 認証・プロジェクトが必要 (このセッションでは `tofu validate` までを保証し、apply は行わない = ローンチ/課金なし)
- 再検討条件: 環境が 3 つ以上に増える、または CI から apply する運用になったら、GCS backend 化と CI 用の権限分離をあわせて見直す
