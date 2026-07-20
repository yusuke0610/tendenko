import Foundation
import GRDB
import Testing

@testable import TendenkoStorage

/// MBTiles 仕様どおりのスキーマでテスト用ファイルを作る。
private func makeMBTiles(at path: String, rows: [(z: Int, x: Int, tmsY: Int, data: Data)]) throws {
    let db = try DatabaseQueue(path: path)
    try db.write { db in
        try db.execute(sql: """
            CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
            CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
            """)
        for r in rows {
            try db.execute(
                sql: "INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)",
                arguments: [r.z, r.x, r.tmsY, r.data])
        }
    }
}

@Suite("MBTilesReader (TMS ⇄ XYZ の Y 反転)")
struct MBTilesReaderTests {
    @Test("z=1 で XYZ y=0 (北) は TMS row=1 (南から数えた上段) に対応する")
    func flipsYCorrectly() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mbtiles").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let north = "north-tile".data(using: .utf8)!
        let south = "south-tile".data(using: .utf8)!
        // z=1: XYZ y=0 (北半球側) は TMS row=1、XYZ y=1 (南半球側) は TMS row=0
        try makeMBTiles(at: path, rows: [(z: 1, x: 0, tmsY: 1, data: north), (z: 1, x: 0, tmsY: 0, data: south)])

        let reader = try MBTilesReader(path: path)
        #expect(try reader.tile(z: 1, x: 0, y: 0) == north)
        #expect(try reader.tile(z: 1, x: 0, y: 1) == south)
    }

    @Test("存在しないタイルは nil")
    func missingTileIsNil() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mbtiles").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeMBTiles(at: path, rows: [])

        let reader = try MBTilesReader(path: path)
        #expect(try reader.tile(z: 10, x: 5, y: 5) == nil)
    }

    // 実データでの疎通確認。例:
    // TENDENKO_MBTILES=$PWD/../../pipeline/out/tiles-584177.mbtiles swift test
    @Test("実データ (釜石メッシュ) からタイルを読める",
          .enabled(if: ProcessInfo.processInfo.environment["TENDENKO_MBTILES"] != nil))
    func realDataSmokeTest() throws {
        let path = ProcessInfo.processInfo.environment["TENDENKO_MBTILES"]!
        let reader = try MBTilesReader(path: path)
        // pipeline 側で確認済み: z=14, tile_column=14654, tms_row=10141 が存在する
        // → xyz y = (2^14 - 1) - 10141 = 6242
        let data = try reader.tile(z: 14, x: 14654, y: 6242)
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }
}
