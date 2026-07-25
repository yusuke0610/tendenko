import Foundation

/// 実行時の設定値。
enum AppConfig {
    /// 地域パッケージの公開配信ベース URL (ADR-0004)。
    /// infra の `packages_public_base_url` 出力の値を入れる:
    ///   https://storage.googleapis.com/<bucket>
    /// 末尾に `/manifest.json` と `/packages/region-<mesh>.sqlite` が付く。
    ///
    /// **未設定 (nil) の間はダウンロードを行わず、同梱サンプル (釜石 584177) にフォールバックする。**
    /// バケットを provision し、ODbL 帰属表示 + A40 条件付き県の除外 (ADR-0002) を済ませた
    /// 公開パッケージを配置してから、ここに URL を設定して有効化する。
    static let packagesBaseURL: URL? = nil

    /// ローリングキャッシュに保持するメッシュ数の上限 (ADR-0004。実機計測で調整)。
    static let cacheBudgetMeshes = 32

    /// ダウンロード済みパッケージのキャッシュディレクトリ。
    /// Caches 配下 (OS がストレージ逼迫時に消しうるが、その場合は再取得すればよい)。
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("regions", isDirectory: true)
    }
}
