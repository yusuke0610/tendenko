import CryptoKit
import Foundation
import TendenkoDomain

/// 地域パッケージのローカルキャッシュを管理する (ADR-0004)。
///
/// 責務: manifest 取得 → 必要メッシュの DL → sha256 検証 → 原子的配置 → キャッシュディレクトリ管理。
/// どのメッシュを保持/退避するかの「計画」はドメイン層の CachePlanner が決め、この型はそれを実行する。
/// ネットワークとファイル I/O をここに隔離する (CLAUDE.md のレイヤ境界)。
public actor RegionPackageStore {
    public enum StoreError: Error, Equatable {
        case manifestNotLoaded
        case checksumMismatch(file: String)
    }

    private let fetcher: PackageFetcher
    private let cacheDir: URL
    private let fm = FileManager.default
    private var manifest: RegionManifest?

    public init(fetcher: PackageFetcher, cacheDirectory: URL) {
        self.fetcher = fetcher
        self.cacheDir = cacheDirectory
    }

    /// manifest を取得して保持する。以後の `ensure` はこの manifest を参照する。
    @discardableResult
    public func refreshManifest() async throws -> RegionManifest {
        let data = try await fetcher.fetchManifest()
        let m = try RegionManifest.decode(data)
        manifest = m
        return m
    }

    /// 指定メッシュのうち未取得のものを DL し、sha256 を検証して原子的に配置する。
    /// manifest に存在しないメッシュ (内陸など) は黙ってスキップする — 縮退モードで成立する (FR-15)。
    public func ensure(meshes: [MeshCode]) async throws {
        guard let manifest else { throw StoreError.manifestNotLoaded }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let byMesh = Dictionary(manifest.packages.map { ($0.mesh, $0) }, uniquingKeysWith: { a, _ in a })
        for mesh in meshes {
            guard let pkg = byMesh[mesh.code] else { continue }
            try await ensureFile(name: pkg.file, sha256: pkg.sha256)
            if let tilesFile = pkg.tilesFile {
                try await ensureFile(name: tilesFile, sha256: pkg.tilesSha256)
            }
        }
    }

    /// キャッシュ済みメッシュ (region.sqlite が存在するもの) をコード昇順で返す。
    /// LRU 順は呼び出し側 (アクセス履歴を持つ調整層) が付ける。
    public func cachedMeshes() -> [MeshCode] {
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return [] }
        var meshes: Set<MeshCode> = []
        for name in names where name.hasPrefix("region-") && name.hasSuffix(".sqlite") {
            let code = String(name.dropFirst("region-".count).dropLast(".sqlite".count))
            if let mesh = MeshCode(code) { meshes.insert(mesh) }
        }
        return meshes.sorted { $0.code < $1.code }
    }

    /// メッシュの region.sqlite のパス (存在すれば)。GraphLoader に渡す。
    public func regionPath(for mesh: MeshCode) -> String? {
        existingPath(cacheDir.appendingPathComponent("region-\(mesh.code).sqlite"))
    }

    /// メッシュの tiles.mbtiles のパス (存在すれば)。MBTilesServer に渡す。
    public func tilesPath(for mesh: MeshCode) -> String? {
        existingPath(cacheDir.appendingPathComponent("tiles-\(mesh.code).mbtiles"))
    }

    /// 退避 (削除)。desired 外のメッシュを CachePlanner の計画に従って消す。
    public func evict(_ meshes: [MeshCode]) {
        for mesh in meshes {
            try? fm.removeItem(atPath: cacheDir.appendingPathComponent("region-\(mesh.code).sqlite").path)
            try? fm.removeItem(atPath: cacheDir.appendingPathComponent("tiles-\(mesh.code).mbtiles").path)
        }
    }

    // MARK: - 内部

    private func ensureFile(name: String, sha256 expected: String?) async throws {
        let dest = cacheDir.appendingPathComponent(name)
        // 既取得ならスキップ (冪等)。検証は DL 時に済んでいる。
        if fm.fileExists(atPath: dest.path) { return }

        let data = try await fetcher.fetchFile(named: name)
        if let expected, Self.sha256Hex(data) != expected {
            throw StoreError.checksumMismatch(file: name)
        }
        // 検証を通ってから原子的に書く (.atomic は temp→rename)。
        // 破損・中途半端なファイルがキャッシュに残らない。
        try data.write(to: dest, options: .atomic)
    }

    private func existingPath(_ url: URL) -> String? {
        fm.fileExists(atPath: url.path) ? url.path : nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
