# 本番環境 (ADR-0005)。配信バケットは公開 (ODbL)、パイプラインは定期実行。
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # state は当面ローカル (この environments/production/ 配下)。本番と staging で
  # ディレクトリごと分離されるため取り違え事故が起きない (ADR-0005)。
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "本番 GCP プロジェクト ID"
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "リージョン (ADR-0001 Stage 1)"
}

variable "packages_bucket_name" {
  type        = string
  description = "配信バケット名 (グローバル一意)"
}

variable "data_bucket_name" {
  type        = string
  description = "入力データバケット名 (グローバル一意)"
}

variable "pipeline_image" {
  type        = string
  default     = ""
  description = "パイプラインイメージ ref。空ならジョブ/スケジューラは作らない (イメージ push 後に設定)"
}

variable "pipeline_uploader" {
  type        = string
  default     = ""
  description = "追加のアップロード権限プリンシパル (任意)"
}

module "tendenko" {
  source = "../../modules/tendenko"

  project_id           = var.project_id
  region               = var.region
  packages_bucket_name = var.packages_bucket_name
  data_bucket_name     = var.data_bucket_name
  pipeline_image       = var.pipeline_image
  pipeline_uploader    = var.pipeline_uploader

  packages_public = true # ODbL の無償入手要件 (ADR-0002)
  enable_schedule = true # 定期実行
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
