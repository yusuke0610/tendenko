# モジュールは required_providers のみ宣言する (provider 設定と backend は呼び出し側の環境)。
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}
