import Foundation
import GRDB
import Testing
import TendenkoDomain

@testable import TendenkoStorage

/// pipeline/internal/pkgwriter と同じスキーマ (ADR-0003) のテスト用 sqlite を作る。
private func makeRegionSQLite(at path: String, meshCode: String,
                              nodes: [(Int64, Double, Double, Double?)],
                              edges: [(Int64, Int64, Double, Double, Double, Int)]) throws {
    let db = try DatabaseQueue(path: path)
    try db.write { db in
        try db.execute(sql: """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE nodes (id INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, elev_m REAL);
            CREATE TABLE edges (from_id INTEGER NOT NULL, to_id INTEGER NOT NULL,
              length_m REAL NOT NULL, grade REAL NOT NULL, bearing_deg REAL NOT NULL, flags INTEGER NOT NULL);
            """)
        try db.execute(sql: "INSERT INTO meta VALUES ('schema_version', '1'), ('mesh', ?)", arguments: [meshCode])
        for n in nodes {
            try db.execute(sql: "INSERT INTO nodes VALUES (?, ?, ?, ?)", arguments: [n.0, n.1, n.2, n.3])
        }
        for e in edges {
            try db.execute(sql: "INSERT INTO edges VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [e.0, e.1, e.2, e.3, e.4, e.5])
        }
    }
}

@Suite("GraphLoader (region.sqlite → RoadGraph)")
struct GraphLoaderTests {
    @Test("読み込みと双方向展開、複数メッシュの結合")
    func loadsAndMerges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // メッシュ A: ノード 1-2、メッシュ B: ノード 2-3 (境界ノード 2 を共有)
        let pathA = dir.appendingPathComponent("region-a.sqlite").path
        let pathB = dir.appendingPathComponent("region-b.sqlite").path
        try makeRegionSQLite(at: pathA, meshCode: "584177",
                             nodes: [(1, 39.25, 141.90, 5.0), (2, 39.26, 141.90, 25.0)],
                             edges: [(1, 2, 1200, 0.016, 10, 8)]) // 浸水フラグ
        try makeRegionSQLite(at: pathB, meshCode: "584178",
                             nodes: [(2, 39.26, 141.90, 25.0), (3, 39.27, 141.90, nil)],
                             edges: [(2, 3, 800, -0.01, 20, 0)])

        let g = try GraphLoader.load(paths: [pathA, pathB])

        #expect(g.nodes.count == 3)
        #expect(g.nodes[1] == GraphNode(lat: 39.25, lon: 141.90, elevM: 5.0))
        #expect(g.nodes[3]?.elevM == nil) // NULL 標高

        // 双方向展開: 1→2 と 2→1 (grade 反転)
        #expect(g.adjacency[1]?.count == 1)
        #expect(g.adjacency[1]?[0].flags == .inundation)
        #expect(g.adjacency[2]?.count == 2) // 2→1 と 2→3 (メッシュ跨ぎ結合)
        let backward = g.adjacency[2]?.first { $0.to == 1 }
        #expect(backward?.grade == -0.016)

        // 結合グラフで経路が引ける (メッシュ境界を跨ぐ)
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [3])
        #expect(r?.nodeIDs == [1, 2, 3])
        #expect(r?.lengthM == 2000)
    }

    @Test("スキーマバージョン不一致は明示的に失敗する")
    func rejectsUnknownSchema() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("region-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO meta VALUES ('schema_version', '99')")
        }
        #expect(throws: GraphLoader.LoaderError.unsupportedSchema(path)) {
            try GraphLoader.load(paths: [path])
        }
    }

    // 実物の region.sqlite での NFR-03 計測。
    // 例: TENDENKO_REGION_SQLITE=$PWD/../../pipeline/out/region-584177.sqlite swift test
    @Test("実データの読込 + 探索時間 (NFR-03 < 5 秒)",
          .enabled(if: ProcessInfo.processInfo.environment["TENDENKO_REGION_SQLITE"] != nil))
    func realDataBenchmark() throws {
        let path = ProcessInfo.processInfo.environment["TENDENKO_REGION_SQLITE"]!
        let t0 = Date()
        let g = try GraphLoader.load(paths: [path])
        let loadSec = Date().timeIntervalSince(t0)

        // 適当なノードから最遠部への探索で下限性能を見る
        let start = g.nodes.keys.min()!
        let goal = g.nodes.keys.max()!
        let t1 = Date()
        _ = EvacuationRouter.route(graph: g, from: start, goals: [goal])
        let routeSec = Date().timeIntervalSince(t1)

        print("bench: nodes=\(g.nodes.count) load=\(String(format: "%.3f", loadSec))s route=\(String(format: "%.3f", routeSec))s")
        #expect(loadSec + routeSec < 5.0)
    }
}
