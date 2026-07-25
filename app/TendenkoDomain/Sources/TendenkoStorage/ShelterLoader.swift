import Foundation
import GRDB
import TendenkoDomain

/// region.sqlite の shelters テーブル (ADR-0003) を [Shelter] に読み込む。
/// 3×3 メッシュ分のファイルを渡すとまとめて読み、メッシュ境界で重複する避難場所
/// (同名・同座標) は 1 件に畳む。
public enum ShelterLoader {
    public static func load(paths: [String]) throws -> [Shelter] {
        var seen: Set<GeoPoint> = []
        var shelters: [Shelter] = []
        for path in paths {
            var config = Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: path, configuration: config)
            try db.read { db in
                let rows = try Row.fetchCursor(
                    db, sql: "SELECT name, lat, lon, elev_m FROM shelters")
                while let r = try rows.next() {
                    let point = GeoPoint(lat: r["lat"], lon: r["lon"])
                    guard seen.insert(point).inserted else { continue }
                    shelters.append(Shelter(name: r["name"], point: point, elevM: r["elev_m"]))
                }
            }
        }
        return shelters
    }
}
