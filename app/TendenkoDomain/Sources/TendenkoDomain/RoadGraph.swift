/// エッジ属性フラグ。pipeline の graph.Flag* と同じビット割り当て (ADR-0003)。
public struct EdgeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let steps = EdgeFlags(rawValue: 1 << 0)         // 階段
    public static let privateAccess = EdgeFlags(rawValue: 1 << 1) // 私道
    public static let bridge = EdgeFlags(rawValue: 1 << 2)        // 橋
    public static let inundation = EdgeFlags(rawValue: 1 << 3)    // 津波浸水想定区域内
}

public struct GraphNode: Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    /// 標高 (m)。DEM データなし (海際など) は nil
    public let elevM: Double?

    public init(lat: Double, lon: Double, elevM: Double?) {
        self.lat = lat
        self.lon = lon
        self.elevM = elevM
    }
}

/// region.sqlite の edges 行そのまま (無向、from→to 向きの属性)。
public struct UndirectedEdge: Sendable, Equatable {
    public let from: Int64
    public let to: Int64
    public let lengthM: Double
    /// 標高差 / 距離 (from→to)。逆向きは符号反転
    public let grade: Double
    public let bearingDeg: Double
    public let flags: EdgeFlags

    public init(from: Int64, to: Int64, lengthM: Double, grade: Double, bearingDeg: Double, flags: EdgeFlags) {
        self.from = from
        self.to = to
        self.lengthM = lengthM
        self.grade = grade
        self.bearingDeg = bearingDeg
        self.flags = flags
    }
}

/// 探索用の有向エッジ。
public struct DirectedEdge: Sendable, Equatable {
    public let to: Int64
    public let lengthM: Double
    public let grade: Double
    public let bearingDeg: Double
    public let flags: EdgeFlags

    public init(to: Int64, lengthM: Double, grade: Double, bearingDeg: Double, flags: EdgeFlags) {
        self.to = to
        self.lengthM = lengthM
        self.grade = grade
        self.bearingDeg = bearingDeg
        self.flags = flags
    }
}

/// 展開済みのメモリ上道路グラフ。ドメイン層の探索はこの値だけを入力にする (純粋)。
public struct RoadGraph: Sendable {
    public let nodes: [Int64: GraphNode]
    public let adjacency: [Int64: [DirectedEdge]]

    /// 無向エッジ列から双方向の隣接リストを作る。
    /// 逆向きは grade の符号を反転し、bearing を 180° 回す (ADR-0003 の端末側展開)。
    public init(nodes: [Int64: GraphNode], undirectedEdges: [UndirectedEdge]) {
        self.nodes = nodes
        var adj: [Int64: [DirectedEdge]] = [:]
        for e in undirectedEdges {
            adj[e.from, default: []].append(
                DirectedEdge(to: e.to, lengthM: e.lengthM, grade: e.grade,
                             bearingDeg: e.bearingDeg, flags: e.flags))
            adj[e.to, default: []].append(
                DirectedEdge(to: e.from, lengthM: e.lengthM, grade: -e.grade,
                             bearingDeg: (e.bearingDeg + 180).truncatingRemainder(dividingBy: 360),
                             flags: e.flags))
        }
        self.adjacency = adj
    }
}
