import Foundation

/// 経路探索の結果とグラフを地図描画用の座標に変換する純粋ロジック (FR-12 の可視化)。
/// 幾何演算のみで I/O を持たないためドメインに置き、TDD する。
public enum RouteGeometry {
    /// Route のノード列を座標列に変換する。グラフに無いノードは飛ばす。
    public static func polyline(_ route: Route, in graph: RoadGraph) -> [GeoPoint] {
        route.nodeIDs.compactMap { id in
            graph.nodes[id].map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        }
    }

    /// point に最も近いグラフノードの ID を返す。ノードが無ければ nil。
    /// 経路探索の始点 (現在地) と goal (避難場所) をグラフ上のノードに丸めるのに使う。
    public static func nearestNode(to point: GeoPoint, in graph: RoadGraph) -> Int64? {
        var bestID: Int64?
        var bestDist = Double.infinity
        for (id, node) in graph.nodes {
            let d = squaredDistance(point, GeoPoint(lat: node.lat, lon: node.lon))
            if d < bestDist {
                bestDist = d
                bestID = id
            }
        }
        return bestID
    }

    /// 浸水想定区域内フラグ (EdgeFlags.inundation) の付いたエッジを、無向で 1 本ずつ座標ペアにする。
    /// avoid-inundation の可視化 (浸水エッジの色分け) に使う。
    public static func inundationSegments(in graph: RoadGraph) -> [[GeoPoint]] {
        var segments: [[GeoPoint]] = []
        for from in graph.nodes.keys.sorted() {
            guard let edges = graph.adjacency[from] else { continue }
            for e in edges where e.flags.contains(.inundation) && from < e.to {
                guard let a = graph.nodes[from], let b = graph.nodes[e.to] else { continue }
                segments.append([GeoPoint(lat: a.lat, lon: a.lon), GeoPoint(lat: b.lat, lon: b.lon)])
            }
        }
        return segments
    }

    /// 経度は緯度が高いほど狭まるため cos(lat) で補正した平面近似の二乗距離。
    /// 最近傍の選択にしか使わないので厳密な測地線距離は不要。
    private static func squaredDistance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let meanLatRad = (a.lat + b.lat) / 2 * .pi / 180
        let dLat = a.lat - b.lat
        let dLon = (a.lon - b.lon) * cos(meanLatRad)
        return dLat * dLat + dLon * dLon
    }
}
