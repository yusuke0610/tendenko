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

    /// 点を経路上に射影した結果。「どこまで進んだか」と「経路からどれだけ離れているか」の組。
    public struct Projection: Sendable, Equatable {
        /// 経路の始点からの道なり距離 (m)
        public let progressM: Double
        /// 経路からの最短距離 (m)
        public let distanceM: Double

        public init(progressM: Double, distanceM: Double) {
            self.progressM = progressM
            self.distanceM = distanceM
        }
    }

    /// 経路の各頂点の、始点からの道なり距離 (m)。要素数は polyline と同じ。
    public static func cumulativeDistancesM(_ polyline: [GeoPoint]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(polyline.count)
        var traveled = 0.0
        for (i, point) in polyline.enumerated() {
            if i > 0 { traveled += polyline[i - 1].distanceM(to: point) }
            out.append(traveled)
        }
        return out
    }

    /// 点を経路上に射影する。経路が空なら nil。
    ///
    /// `searchRangeM` を渡すと、その道なり距離の範囲に掛かる線分だけを候補にする。
    /// 全体から最近傍を選ぶと、九十九折り・自己交差・並走区間で測位誤差により先の区間が
    /// 近くなり、進行が一気に飛ぶ (`RouteTracker` が間の案内をまとめて捨てる)。
    /// 範囲を跨ぐ線分は候補に含めるので、進行の上限は「範囲の端が乗る線分の終端」になる。
    public static func project(_ point: GeoPoint, onto polyline: [GeoPoint],
                               searchRangeM: ClosedRange<Double>? = nil) -> Projection? {
        guard let first = polyline.first else { return nil }
        guard polyline.count > 1 else {
            if let range = searchRangeM, !range.contains(0) { return nil }
            return Projection(progressM: 0, distanceM: point.distanceM(to: first))
        }

        let cumulative = cumulativeDistancesM(polyline)
        var best: Projection?
        for i in 0..<(polyline.count - 1) {
            let start = cumulative[i], end = cumulative[i + 1]
            if let range = searchRangeM, end < range.lowerBound || start > range.upperBound {
                continue
            }
            let (distance, t) = distanceAndProjection(point, polyline[i], polyline[i + 1])
            if distance < (best?.distanceM ?? .infinity) {
                best = Projection(progressM: start + (end - start) * t, distanceM: distance)
            }
        }
        return best
    }

    /// 点から折れ線までの最短距離 (m)。経路からの逸脱判定 (FR-14) に使う。
    /// 折れ線が空なら無限遠を返す (経路が無い状態は「常に逸脱」として扱えるようにする)。
    public static func distanceToPolylineM(_ point: GeoPoint, polyline: [GeoPoint]) -> Double {
        project(point, onto: polyline)?.distanceM ?? .infinity
    }

    /// 点を経路上に射影したときの、経路の始点からの道なり距離 (m)。
    ///
    /// 「どこまで進んだか」を測る唯一の基準。案内地点との直線距離で進行を判定すると、
    /// 通り過ぎた指示を飛ばせず (遠ざかると近さの条件を満たさない)、進行が止まる。
    public static func progressAlongPolylineM(_ point: GeoPoint, polyline: [GeoPoint]) -> Double {
        project(point, onto: polyline)?.progressM ?? 0
    }

    /// 点から線分までの距離 (m) と、線分上の射影位置 (0…1)。
    /// 線分は数十〜数百 m なので、線分の始点を原点とする局所平面 (東西を cos(lat) 補正) で計算する。
    /// 地球半径は haversine と揃えてあるので、道なり距離との整合が取れる。
    private static func distanceAndProjection(_ p: GeoPoint, _ a: GeoPoint,
                                              _ b: GeoPoint) -> (distanceM: Double, t: Double) {
        let lat0 = (a.lat + b.lat) / 2 * .pi / 180
        let mPerDegLat = GeoPoint.earthRadiusM * .pi / 180
        let mPerDegLon = mPerDegLat * cos(lat0)

        func project(_ q: GeoPoint) -> (x: Double, y: Double) {
            ((q.lon - a.lon) * mPerDegLon, (q.lat - a.lat) * mPerDegLat)
        }
        let pv = project(p), bv = project(b)

        let lengthSquared = bv.x * bv.x + bv.y * bv.y
        // 線分が潰れている (同一点) 場合は端点までの距離
        guard lengthSquared > 0 else { return (p.distanceM(to: a), 0) }

        // 線分上への射影を [0,1] に丸める。範囲外なら最寄りの端点が最短になる
        var t = (pv.x * bv.x + pv.y * bv.y) / lengthSquared
        t = min(max(t, 0), 1)

        let dx = pv.x - bv.x * t
        let dy = pv.y - bv.y * t
        return ((dx * dx + dy * dy).squareRoot(), t)
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
