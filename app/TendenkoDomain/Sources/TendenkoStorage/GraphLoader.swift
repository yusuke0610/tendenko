import Foundation
import GRDB
import TendenkoDomain

/// region.sqlite (ADR-0003 スキーマ) を読み込み、展開済みの RoadGraph を作る。
/// ローリングキャッシュの 3×3 メッシュ分のファイルをまとめて渡すと結合される
/// (ノード ID がグローバルなので単純結合でメッシュ境界を跨げる)。
public enum GraphLoader {
    public enum LoaderError: Error, Equatable {
        case unsupportedSchema(String)
    }

    public static func load(paths: [String]) throws -> RoadGraph {
        var nodes: [Int64: GraphNode] = [:]
        var edges: [UndirectedEdge] = []

        for path in paths {
            var config = Configuration()
            config.readonly = true
            let db = try DatabaseQueue(path: path, configuration: config)
            try db.read { db in
                guard let version = try String.fetchOne(
                    db, sql: "SELECT value FROM meta WHERE key = 'schema_version'"), version == "1"
                else {
                    throw LoaderError.unsupportedSchema(path)
                }
                let nodeRows = try Row.fetchCursor(db, sql: "SELECT id, lat, lon, elev_m FROM nodes")
                while let r = try nodeRows.next() {
                    nodes[r["id"]] = GraphNode(lat: r["lat"], lon: r["lon"], elevM: r["elev_m"])
                }
                let edgeRows = try Row.fetchCursor(
                    db, sql: "SELECT from_id, to_id, length_m, grade, bearing_deg, flags FROM edges")
                while let r = try edgeRows.next() {
                    edges.append(UndirectedEdge(
                        from: r["from_id"], to: r["to_id"],
                        lengthM: r["length_m"], grade: r["grade"], bearingDeg: r["bearing_deg"],
                        flags: EdgeFlags(rawValue: UInt32(r["flags"] as Int64))))
                }
            }
        }
        return RoadGraph(nodes: nodes, undirectedEdges: edges)
    }
}
