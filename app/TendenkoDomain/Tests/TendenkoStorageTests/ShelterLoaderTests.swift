import Foundation
import GRDB
import Testing
import TendenkoDomain

@testable import TendenkoStorage

private func makeRegionWithShelters(at path: String,
                                    shelters: [(String, Double, Double, Double?)]) throws {
    let db = try DatabaseQueue(path: path)
    try db.write { db in
        try db.execute(sql: """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE shelters (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
              lat REAL NOT NULL, lon REAL NOT NULL, elev_m REAL);
            """)
        try db.execute(sql: "INSERT INTO meta VALUES ('schema_version', '1')")
        for s in shelters {
            try db.execute(sql: "INSERT INTO shelters (name, lat, lon, elev_m) VALUES (?, ?, ?, ?)",
                           arguments: [s.0, s.1, s.2, s.3])
        }
    }
}

@Suite("ShelterLoader (region.sqlite → [Shelter])")
struct ShelterLoaderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("避難場所を読み込む (標高 nil を含む)")
    func loadsShelters() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("region-a.sqlite").path
        try makeRegionWithShelters(at: path, shelters: [
            ("鵜住居小学校・釜石東中学校校庭", 39.30, 141.94, 25.0),
            ("高台の広場", 39.31, 141.95, nil),
        ])
        let shelters = try ShelterLoader.load(paths: [path])
        #expect(shelters.count == 2)
        #expect(shelters.contains { $0.name == "鵜住居小学校・釜石東中学校校庭" && $0.elevM == 25.0 })
        #expect(shelters.contains { $0.point == GeoPoint(lat: 39.31, lon: 141.95) && $0.elevM == nil })
    }

    @Test("複数メッシュで同座標の避難場所は 1 件に畳む")
    func dedupsAcrossMeshes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("region-a.sqlite").path
        let b = dir.appendingPathComponent("region-b.sqlite").path
        try makeRegionWithShelters(at: a, shelters: [("避難所X", 39.30, 141.94, 20)])
        try makeRegionWithShelters(at: b, shelters: [("避難所X", 39.30, 141.94, 20),
                                                     ("避難所Y", 39.32, 141.96, 30)])
        let shelters = try ShelterLoader.load(paths: [a, b])
        #expect(shelters.count == 2) // X は重複排除、Y は追加
    }

    @Test("shelters が空でも空配列を返す")
    func emptyShelters() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("region-a.sqlite").path
        try makeRegionWithShelters(at: path, shelters: [])
        #expect(try ShelterLoader.load(paths: [path]).isEmpty)
    }
}
