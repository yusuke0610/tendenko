# 検証環境 (ADR-0005)。本番と別プロジェクト/バケット。実インフラ経路 (job 実行 → アップロード
# → アプリが公開 URL から取得) をローンチ前に隔離して検証する。定期実行はせず手動起動。
# 検証データのみを置き、検証後に破棄する運用とする。
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # state は当面ローカル (この environments/staging/ 配下)。production とディレクトリごと
  # 分離されるため、staging の apply/destroy が本番に影響しない (ADR-0005)。
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "検証用 GCP プロジェクト ID (本番と別プロジェクト推奨)"
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "リージョン"
}

variable "packages_bucket_name" {
  type        = string
  description = "検証用 配信バケット名 (グローバル一意、本番と別名)"
}

variable "data_bucket_name" {
  type        = string
  description = "検証用 入力データバケット名 (グローバル一意、本番と別名)"
}

variable "pipeline_image" {
  type        = string
  default     = ""
  description = "パイプラインイメージ ref。空ならジョブは作らない (イメージ push 後に設定)"
}

variable "pipeline_uploader" {
  type        = string
  default     = ""
  description = "追加のアップロード権限プリンシパル (任意。手元から検証アップロードする場合など)"
}

module "tendenko" {
  source = "../../modules/tendenko"

  project_id           = var.project_id
  region               = var.region
  packages_bucket_name = var.packages_bucket_name
  data_bucket_name     = var.data_bucket_name
  pipeline_image       = var.pipeline_image
  pipeline_uploader    = var.pipeline_uploader

  # 検証もアプリの実 DL を試すため公開読み取り (別バケット・検証データのみ、検証後破棄)。
  packages_public = true
  # 検証は手動起動 (Cloud Scheduler を作らない)。
  enable_schedule = false

  # 検証はリソースを小さめに (全国 run はしない前提。少数メッシュの検証用)。
  pipeline_cpu    = "2"
  pipeline_memory = "8Gi"
}

output "packages_public_base_url" {
  value = module.tendenko.packages_public_base_url
}

output "packages_bucket_url" {
  value = module.tendenko.packages_bucket_url
}

output "data_bucket_url" {
  value = module.tendenko.data_bucket_url
}

output "pipeline_image_repo" {
  value = module.tendenko.pipeline_image_repo
}
