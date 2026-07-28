import Foundation
import GRDB

/// region.sqlite の meta テーブルを読む薄い層。
/// いまは帰属表示 (attributions) に使う。パッケージごとに含まれるデータの出典が異なるため、
/// アプリは表示中パッケージの meta から帰属を組み立てる (ADR-0002)。
public enum MetaLoader {
    /// meta.attributions (パイプラインが改行区切りで格納) を配列で返す。
    /// キーが無い / 空の古いパッケージでは空配列。
    public static func attributions(path: String) throws -> [String] {
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: path, configuration: config)
        return try db.read { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'attributions'"), !raw.isEmpty
            else { return [] }
            return raw.split(separator: "\n").map(String.init)
        }
    }
}
