# 地域パッケージ配信バケット (ADR-0004)。
#
# 公開 (public-read) にする: 配布物は OSM 由来の派生データベースで、ODbL の share-alike に
# より「無償で入手可能」であることが求められる (ADR-0002 決定)。公開配信が share-alike の
# 履行そのものであり、認証・署名 URL でのアクセス制限は ODbL の anti-TPM 条項と衝突する。
# したがって allUsers に objectViewer を付け、public_access_prevention は inherited にする。
#
# 前提 (ADR-0002): 公開パッケージには OSM 帰属を付け、A40 条件付き県の由来フラグを除外した
# 上で再生成すること。
resource "google_storage_bucket" "packages" {
  name     = var.packages_bucket_name
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true
  # 公開配信を許可する (allUsers:objectViewer を下で付与)。組織ポリシーで
  # domain restricted sharing が有効な場合は例外設定が必要になることがある。
  public_access_prevention = "inherited"

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

# 公開読み取り (ODbL の無償入手要件を満たす)。オブジェクトの読み取りのみ。
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# パイプライン (Cloud Run jobs) がアップロードするための権限。
# pipeline_uploader が空なら付与しない (ローカルから自分の権限で上げる開発時)。
resource "google_storage_bucket_iam_member" "uploader" {
  count  = var.pipeline_uploader == "" ? 0 : 1
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectAdmin"
  member = var.pipeline_uploader
}
