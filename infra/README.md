# infra/

OpenTofu によるインフラ定義。構成は [ADR-0001](../docs/adr/0001-execution-platform.md) の **Stage 1 (MVP)**、環境分離は [ADR-0005](../docs/adr/0005-infra-environments.md) に従う。

## 構成

```
infra/
  modules/tendenko/     # 全リソースを集約した再利用モジュール (provider/backend は持たない)
  environments/
    production/         # 本番: 配信バケット公開 + 定期実行
    staging/           # 検証: 別プロジェクト/バケット、手動起動、検証後破棄
```

- **リソース定義はモジュール 1 箇所**。環境差分は変数 (`packages_public` / `enable_schedule` / バケット名 / project_id 等) だけ
- 環境ごとに **state もディレクトリも物理分離**され、staging の `apply`/`destroy` が本番に影響しない
- 主なリソース: 地域パッケージ配信バケット ([ADR-0004](../docs/adr/0004-region-package-delivery.md))、パイプライン入力データバケット、Artifact Registry、Cloud Run job + Cloud Scheduler、SA/IAM

## 実行

`make` 経由で環境を `ENV` で指定する (デフォルトは事故防止のため `staging`)。

```
# 初回: 値を入れる
cp infra/environments/staging/terraform.tfvars.example infra/environments/staging/terraform.tfvars

make infra-init  ENV=staging
make infra-plan  ENV=staging
make infra-apply ENV=staging      # 要 GCP 認証
```

`ENV=production` で本番。`plan`/`apply` には GCP プロジェクトと認証が必要。state は当面ローカル (GCS backend 化は state 用バケットの bootstrap 後、ADR-0005)。
