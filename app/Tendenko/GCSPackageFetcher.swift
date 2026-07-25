import Foundation
import TendenkoStorage

/// 公開 GCS バケットから manifest とパッケージを取得する PackageFetcher の本番実装 (ADR-0004)。
///
/// GCS の URL の形 (バケット・packages/ プレフィックス) という「インフラの形」はこの型に閉じ込め、
/// RegionPackageStore のロジックには漏らさない (CLAUDE.md のレイヤ境界)。
struct GCSPackageFetcher: PackageFetcher {
    /// 例: https://storage.googleapis.com/<bucket>
    let baseURL: URL

    func fetchManifest() async throws -> Data {
        try await get(baseURL.appendingPathComponent("manifest.json"))
    }

    func fetchFile(named name: String) async throws -> Data {
        // ADR-0004 のレイアウト: パッケージ本体は packages/ 配下
        try await get(baseURL.appendingPathComponent("packages").appendingPathComponent(name))
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
