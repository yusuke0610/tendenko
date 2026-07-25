import Foundation

/// 地域パッケージ・manifest の取得元を抽象化する (ADR-0004)。
///
/// GCS の URL 構築やバケット名という「インフラの形」は本番実装 (app ターゲット側) に
/// 閉じ込め、RegionPackageStore のロジックには漏らさない。テストは fake 実装を注入する。
public protocol PackageFetcher: Sendable {
    /// manifest.json の生バイト列を取得する。
    func fetchManifest() async throws -> Data
    /// manifest の `file` / `tiles_file` 名で単一パッケージファイルを取得する。
    func fetchFile(named name: String) async throws -> Data
}
