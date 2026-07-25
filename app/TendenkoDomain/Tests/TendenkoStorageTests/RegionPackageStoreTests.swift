import CryptoKit
import Foundation
import Testing
import TendenkoDomain

@testable import TendenkoStorage

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// ネットワークの代わりにメモリ上のバイト列を返す fake。DL 回数も数える。
private actor FakeFetcher: PackageFetcher {
    private let manifestData: Data
    private let files: [String: Data]
    private(set) var fetchCounts: [String: Int] = [:]

    init(manifestData: Data, files: [String: Data]) {
        self.manifestData = manifestData
        self.files = files
    }

    func fetchManifest() async throws -> Data { manifestData }

    func fetchFile(named name: String) async throws -> Data {
        fetchCounts[name, default: 0] += 1
        guard let data = files[name] else {
            throw NSError(domain: "FakeFetcher", code: 404)
        }
        return data
    }

    func count(_ name: String) -> Int { fetchCounts[name, default: 0] }
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return dir
}

@Suite("RegionPackageStore — DL・検証・キャッシュ管理 (ADR-0004)")
struct RegionPackageStoreTests {
    // 釜石メッシュのダミー region/tiles バイト列と、それを指す manifest を作る。
    private func fixture(regionData: Data, tilesData: Data)
        -> (manifest: Data, files: [String: Data])
    {
        let manifest = """
        {
          "schema_version": 1,
          "generated_at": "2026-07-25T00:00:00Z",
          "packages": [
            {
              "mesh": "584177",
              "file": "region-584177.sqlite",
              "bytes": \(regionData.count),
              "sha256": "\(sha256(regionData))",
              "nodes": 3, "edges": 2,
              "tiles_file": "tiles-584177.mbtiles",
              "tiles_bytes": \(tilesData.count),
              "tiles_sha256": "\(sha256(tilesData))"
            }
          ]
        }
        """
        return (Data(manifest.utf8),
                ["region-584177.sqlite": regionData, "tiles-584177.mbtiles": tilesData])
    }

    @Test("manifest を snake_case でデコードできる")
    func decodesManifest() throws {
        let (data, _) = fixture(regionData: Data("r".utf8), tilesData: Data("t".utf8))
        let m = try RegionManifest.decode(data)
        #expect(m.schemaVersion == 1)
        #expect(m.packages.first?.mesh == "584177")
        #expect(m.packages.first?.tilesFile == "tiles-584177.mbtiles")
    }

    @Test("ensure が region と tiles を DL・検証して配置し、パスを引ける")
    func ensureDownloadsAndPlaces() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let region = Data("region-bytes".utf8)
        let tiles = Data("tiles-bytes".utf8)
        let (manifest, files) = fixture(regionData: region, tilesData: tiles)
        let store = RegionPackageStore(fetcher: FakeFetcher(manifestData: manifest, files: files),
                                       cacheDirectory: dir)
        try await store.refreshManifest()
        try await store.ensure(meshes: [MeshCode("584177")!])

        let regionPath = await store.regionPath(for: MeshCode("584177")!)
        let tilesPath = await store.tilesPath(for: MeshCode("584177")!)
        #expect(regionPath != nil)
        #expect(tilesPath != nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: regionPath!)) == region)
        let cached = await store.cachedMeshes()
        #expect(cached == [MeshCode("584177")!])
    }

    @Test("チェックサム不一致は例外を投げ、破損ファイルを残さない")
    func checksumMismatchRejected() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // manifest は正しい region のハッシュを載せるが、fetcher は別バイトを返す
        let region = Data("correct".utf8)
        let (manifest, _) = fixture(regionData: region, tilesData: Data("t".utf8))
        let corrupt = ["region-584177.sqlite": Data("TAMPERED".utf8),
                       "tiles-584177.mbtiles": Data("t".utf8)]
        let store = RegionPackageStore(fetcher: FakeFetcher(manifestData: manifest, files: corrupt),
                                       cacheDirectory: dir)
        try await store.refreshManifest()
        await #expect(throws: RegionPackageStore.StoreError.checksumMismatch(file: "region-584177.sqlite")) {
            try await store.ensure(meshes: [MeshCode("584177")!])
        }
        let path = await store.regionPath(for: MeshCode("584177")!)
        #expect(path == nil) // 破損ファイルは配置されない
    }

    @Test("既取得のファイルは再 DL しない (冪等)")
    func ensureIsIdempotent() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (manifest, files) = fixture(regionData: Data("r".utf8), tilesData: Data("t".utf8))
        let fetcher = FakeFetcher(manifestData: manifest, files: files)
        let store = RegionPackageStore(fetcher: fetcher, cacheDirectory: dir)
        try await store.refreshManifest()
        try await store.ensure(meshes: [MeshCode("584177")!])
        try await store.ensure(meshes: [MeshCode("584177")!])
        #expect(await fetcher.count("region-584177.sqlite") == 1)
    }

    @Test("manifest に無いメッシュは黙ってスキップする (縮退モードで成立 / FR-15)")
    func unknownMeshSkipped() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (manifest, files) = fixture(regionData: Data("r".utf8), tilesData: Data("t".utf8))
        let store = RegionPackageStore(fetcher: FakeFetcher(manifestData: manifest, files: files),
                                       cacheDirectory: dir)
        try await store.refreshManifest()
        try await store.ensure(meshes: [MeshCode("362257")!]) // manifest に無い内陸メッシュ
        let cached = await store.cachedMeshes()
        #expect(cached.isEmpty)
    }

    @Test("evict は region と tiles を削除する")
    func evictRemovesFiles() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (manifest, files) = fixture(regionData: Data("r".utf8), tilesData: Data("t".utf8))
        let store = RegionPackageStore(fetcher: FakeFetcher(manifestData: manifest, files: files),
                                       cacheDirectory: dir)
        try await store.refreshManifest()
        try await store.ensure(meshes: [MeshCode("584177")!])
        await store.evict([MeshCode("584177")!])
        #expect(await store.regionPath(for: MeshCode("584177")!) == nil)
        #expect(await store.tilesPath(for: MeshCode("584177")!) == nil)
    }

    @Test("manifest 未取得で ensure すると明示的に失敗する")
    func ensureWithoutManifestFails() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RegionPackageStore(fetcher: FakeFetcher(manifestData: Data(), files: [:]),
                                       cacheDirectory: dir)
        await #expect(throws: RegionPackageStore.StoreError.manifestNotLoaded) {
            try await store.ensure(meshes: [MeshCode("584177")!])
        }
    }
}
