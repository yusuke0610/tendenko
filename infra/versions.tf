terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # 当面はローカル state。infra の第一資源がこの配信バケットであり、
  # GCS backend はチキンエッグ (state 用バケットを別途 bootstrap してから) になるため後回し。
}
