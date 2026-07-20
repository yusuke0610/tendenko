import Foundation
import GRDB

/// MBTiles (tilemaker が生成する OpenMapTiles スキーマ) から 1 タイル分のバイト列を読む。
/// MBTiles 仕様の tile_row は TMS 方式 (南→北) であり、地図ライブラリが使う XYZ 方式
/// (北→南) とは Y が反転している。
public struct MBTilesReader {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    /// z/x/y (XYZ 方式) のタイルデータを返す。存在しなければ nil。
    public func tile(z: Int, x: Int, y: Int) throws -> Data? {
        let tmsRow = (1 << z) - 1 - y
        return try dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
                arguments: [z, x, tmsRow])
        }
    }
}
