# 地域パッケージ配信バケット (ADR-0004)。
#
# 当面は非公開 (private) に倒す: 配布物は OSM 由来データで、ODbL share-alike 義務が
# ADR-0002 で未整理のまま残っている。world-public 化 (= 公開配布) はその義務を発火させる
# ため、ライセンス整理が済むまで allUsers を付けない。public_access_prevention = "enforced"
# で誤って公開されることも防ぐ。app からの取得はこの制約解除後 (別 PR) に繋ぐ。
resource "google_storage_bucket" "packages" {
  name     = var.packages_bucket_name
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # manifest / パッケージは上書き配信するため世代管理を有効化し、直近数世代のみ残す。
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

# パイプライン (Cloud Run jobs) がアップロードするための権限。
# pipeline_uploader が空なら付与しない (ローカルから自分の権限で上げる開発時)。
resource "google_storage_bucket_iam_member" "uploader" {
  count  = var.pipeline_uploader == "" ? 0 : 1
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectAdmin"
  member = var.pipeline_uploader
}
