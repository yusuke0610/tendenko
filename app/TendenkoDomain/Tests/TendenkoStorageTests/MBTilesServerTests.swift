import Foundation
import GRDB
import Testing

@testable import TendenkoStorage

@Suite("MBTilesServer のパス解析 (純粋関数)")
struct MBTilesServerPathParsingTests {
    @Test("リクエスト行からパスを取り出す")
    func parsesPath() {
        let req = "GET /14/14654/6242.pbf HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(MBTilesServer.parsePath(from: req) == "/14/14654/6242.pbf")
    }

    @Test("z/x/y.pbf を TileCoordinate に変換する")
    func parsesTileCoordinate() {
        #expect(MBTilesServer.parseTileCoordinate(from: "/14/14654/6242.pbf") == TileCoordinate(z: 14, x: 14654, y: 6242))
        #expect(MBTilesServer.parseTileCoordinate(from: "14/14654/6242.pbf") == TileCoordinate(z: 14, x: 14654, y: 6242))
    }

    @Test("不正なパスは nil")
    func rejectsInvalidPath() {
        #expect(MBTilesServer.parseTileCoordinate(from: "/not-a-tile") == nil)
        #expect(MBTilesServer.parseTileCoordinate(from: "/1/2/abc.pbf") == nil)
    }

    @Test("gzip マジックバイトを検出する (tilemaker の tile_data は gzip 圧縮済み)")
    func detectsGzipMagicBytes() {
        #expect(MBTilesServer.isGzip(Data([0x1f, 0x8b, 0x08, 0x00])))
        #expect(!MBTilesServer.isGzip(Data([0x00, 0x01])))
        #expect(!MBTilesServer.isGzip(Data()))
    }
}

@Suite("MBTilesServer の HTTP 応答 (実際にソケットへ接続)")
struct MBTilesServerIntegrationTests {
    @Test("存在するタイルを 200 で返し、存在しないタイルは 404")
    func servesTiles() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mbtiles").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let payload = Data("hello-tile".utf8)
        let db = try DatabaseQueue(path: path)
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
                CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
                """)
            try db.execute(
                sql: "INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (1, 0, 1, ?)",
                arguments: [payload])
        }

        let server = try MBTilesServer(mbtilesPath: path)
        try server.start()
        defer { server.stop() }

        let (status200, body) = try await httpGet(port: server.port, path: "/1/0/0.pbf")
        #expect(status200 == 200)
        #expect(body == payload)

        let (status404, _) = try await httpGet(port: server.port, path: "/1/0/1.pbf")
        #expect(status404 == 404)
    }
}

/// GET リクエストを送り (ステータスコード, ボディ) を返す最小 HTTP クライアント。
private func httpGet(port: UInt16, path: String) async throws -> (Int, Data) {
    let (data, response) = try await URLSession.shared.data(
        for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!))
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, data)
}
