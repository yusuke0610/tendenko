import Foundation
import GRDB
import Testing

@testable import TendenkoStorage

private func makeRegionWithMeta(at path: String, attributions: String?) throws {
    let db = try DatabaseQueue(path: path)
    try db.write { db in
        try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute(sql: "INSERT INTO meta VALUES ('schema_version','1')")
        if let attributions {
            try db.execute(sql: "INSERT INTO meta VALUES ('attributions', ?)", arguments: [attributions])
        }
    }
}

@Suite("MetaLoader (region.sqlite の meta.attributions)")
struct MetaLoaderTests {
    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("region.sqlite").path
    }

    @Test("改行区切りの attributions を配列にする")
    func parsesAttributions() throws {
        let path = tempPath()
        try makeRegionWithMeta(at: path, attributions: "OpenStreetMap contributors\n国土地理院\n福井県")
        #expect(try MetaLoader.attributions(path: path) == ["OpenStreetMap contributors", "国土地理院", "福井県"])
    }

    @Test("attributions キーが無い古いパッケージは空配列")
    func missingKeyIsEmpty() throws {
        let path = tempPath()
        try makeRegionWithMeta(at: path, attributions: nil)
        #expect(try MetaLoader.attributions(path: path).isEmpty)
    }
}
