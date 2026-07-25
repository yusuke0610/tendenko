import Testing

@testable import TendenkoDomain

private func edge(_ from: Int64, _ to: Int64, flags: EdgeFlags = []) -> UndirectedEdge {
    UndirectedEdge(from: from, to: to, lengthM: 100, grade: 0, bearingDeg: 0, flags: flags)
}

/// 座標付きの合成グラフ。ノード id = 緯度経度の目印。
private func graph(nodes: [(Int64, Double, Double)], edges: [UndirectedEdge]) -> RoadGraph {
    var dict: [Int64: GraphNode] = [:]
    for n in nodes { dict[n.0] = GraphNode(lat: n.1, lon: n.2, elevM: nil) }
    return RoadGraph(nodes: dict, undirectedEdges: edges)
}

@Suite("RouteGeometry — 経路と浸水エッジの座標化 (FR-12 可視化)")
struct RouteGeometryTests {
    @Test("Route の nodeIDs を座標列に変換する")
    func polylineFromRoute() {
        let g = graph(nodes: [(1, 39.25, 141.90), (2, 39.26, 141.91), (3, 39.27, 141.92)],
                      edges: [edge(1, 2), edge(2, 3)])
        let route = Route(nodeIDs: [1, 2, 3], cost: 0, lengthM: 200)
        let line = RouteGeometry.polyline(route, in: g)
        #expect(line == [GeoPoint(lat: 39.25, lon: 141.90),
                         GeoPoint(lat: 39.26, lon: 141.91),
                         GeoPoint(lat: 39.27, lon: 141.92)])
    }

    @Test("欠損ノードは座標列から除外する")
    func polylineSkipsMissing() {
        let g = graph(nodes: [(1, 39.25, 141.90), (3, 39.27, 141.92)], edges: [])
        let route = Route(nodeIDs: [1, 2, 3], cost: 0, lengthM: 0)
        #expect(RouteGeometry.polyline(route, in: g).count == 2)
    }

    @Test("現在地に最も近いグラフノードを返す")
    func nearestNodePicksClosest() {
        let g = graph(nodes: [(1, 39.20, 141.90), (2, 39.30, 141.90), (3, 39.40, 141.90)],
                      edges: [edge(1, 2), edge(2, 3)])
        let near = RouteGeometry.nearestNode(to: GeoPoint(lat: 39.31, lon: 141.90), in: g)
        #expect(near == 2)
    }

    @Test("空グラフの最近傍は nil")
    func nearestNodeEmpty() {
        let g = graph(nodes: [], edges: [])
        #expect(RouteGeometry.nearestNode(to: GeoPoint(lat: 0, lon: 0), in: g) == nil)
    }

    @Test("浸水フラグ付きエッジを無向で 1 回ずつ座標ペアにする")
    func inundationSegmentsDedup() {
        let g = graph(nodes: [(1, 39.25, 141.90), (2, 39.26, 141.91), (3, 39.27, 141.92)],
                      edges: [edge(1, 2, flags: .inundation), edge(2, 3)]) // 2-3 は浸水なし
        let segs = RouteGeometry.inundationSegments(in: g)
        #expect(segs.count == 1) // 双方向展開されても 1 本
        let seg = segs[0]
        #expect(Set(seg) == Set([GeoPoint(lat: 39.25, lon: 141.90),
                                 GeoPoint(lat: 39.26, lon: 141.91)]))
    }

    @Test("浸水フラグが無ければ空")
    func inundationSegmentsNone() {
        let g = graph(nodes: [(1, 39.25, 141.90), (2, 39.26, 141.91)], edges: [edge(1, 2)])
        #expect(RouteGeometry.inundationSegments(in: g).isEmpty)
    }
}
