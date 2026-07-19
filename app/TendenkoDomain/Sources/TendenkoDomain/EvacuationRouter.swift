/// 経路コストの重み (FR-12)。「最短」ではなく「浸水リスク最小 + 迷いにくさ」。
/// 重みはチューニング対象なので値で持ち、探索時に動的に計算する (ADR-0003)。
public struct CostModel: Sendable {
    /// 浸水想定区域内のコスト倍率
    public var inundationFactor: Double = 4.0
    /// 階段のコスト倍率 (通れるが遅い・夜間や群衆で危険)
    public var stepsFactor: Double = 2.0
    /// 私道のコスト倍率 (実際は通れない可能性が高い)
    public var privateAccessFactor: Double = 10.0
    /// 下り勾配 1.0 (100%) あたりのコスト倍率増分。「低い方へ向かう経路を罰する」
    public var downhillFactor: Double = 8.0
    /// 方向転換 1 回あたりのペナルティ (メートル相当)。「曲がり回数の少ない経路を優先」
    public var turnPenaltyM: Double = 15.0
    /// これ以上の方位差 (度) を方向転換とみなす
    public var turnThresholdDeg: Double = 45.0

    public init() {}

    public func edgeCost(_ e: DirectedEdge) -> Double {
        var c = e.lengthM
        if e.flags.contains(.inundation) { c *= inundationFactor }
        if e.flags.contains(.steps) { c *= stepsFactor }
        if e.flags.contains(.privateAccess) { c *= privateAccessFactor }
        if e.grade < 0 { c *= 1 + downhillFactor * (-e.grade) }
        return c
    }

    /// 直前エッジの方位からの転換コスト。最初のエッジ (previous == nil) は 0。
    public func turnCost(previousBearingDeg: Double?, nextBearingDeg: Double) -> Double {
        guard let prev = previousBearingDeg else { return 0 }
        var diff = abs(nextBearingDeg - prev).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff > turnThresholdDeg ? turnPenaltyM : 0
    }
}

public struct Route: Sendable, Equatable {
    /// 始点から目的地までのノード列 (始点含む)
    public let nodeIDs: [Int64]
    /// コスト関数値の合計 (メートル相当)
    public let cost: Double
    /// 実距離の合計 (m)
    public let lengthM: Double
}

/// 避難経路探索。展開済みグラフ → 経路の純粋関数 (CLAUDE.md の TDD 境界)。
public enum EvacuationRouter {
    /// start から goals のいずれかへの最小コスト経路を返す。到達不能なら nil。
    /// ターンペナルティを扱うため、状態はノードではなく「直前に使ったエッジ」で持つ。
    public static func route(
        graph: RoadGraph,
        from start: Int64,
        goals: Set<Int64>,
        cost model: CostModel = CostModel()
    ) -> Route? {
        guard graph.nodes[start] != nil, !goals.isEmpty else { return nil }
        if goals.contains(start) {
            return Route(nodeIDs: [start], cost: 0, lengthM: 0)
        }

        struct EdgeKey: Hashable {
            let from: Int64
            let to: Int64
        }
        struct State {
            let key: EdgeKey
            let bearingDeg: Double
            let cost: Double
            let lengthM: Double
        }

        var best: [EdgeKey: Double] = [:]
        var parent: [EdgeKey: EdgeKey] = [:]
        var lengthTo: [EdgeKey: Double] = [:]
        var heap = BinaryHeap<State> { $0.cost < $1.cost }

        for e in graph.adjacency[start] ?? [] {
            let key = EdgeKey(from: start, to: e.to)
            let c = model.edgeCost(e)
            if c < best[key] ?? .infinity {
                best[key] = c
                lengthTo[key] = e.lengthM
                heap.push(State(key: key, bearingDeg: e.bearingDeg, cost: c, lengthM: e.lengthM))
            }
        }

        while let s = heap.pop() {
            if s.cost > (best[s.key] ?? .infinity) { continue } // 陳腐化したエントリ
            if goals.contains(s.key.to) {
                return Route(nodeIDs: reconstruct(parent: parent, last: s.key, start: start),
                             cost: s.cost, lengthM: s.lengthM)
            }
            for e in graph.adjacency[s.key.to] ?? [] {
                if e.to == s.key.from { continue } // 直前のノードへの即 U ターンは展開しない
                let key = EdgeKey(from: s.key.to, to: e.to)
                let c = s.cost + model.edgeCost(e)
                    + model.turnCost(previousBearingDeg: s.bearingDeg, nextBearingDeg: e.bearingDeg)
                if c < best[key] ?? .infinity {
                    best[key] = c
                    parent[key] = s.key
                    lengthTo[key] = s.lengthM + e.lengthM
                    heap.push(State(key: key, bearingDeg: e.bearingDeg, cost: c,
                                    lengthM: s.lengthM + e.lengthM))
                }
            }
        }
        return nil

        func reconstruct(parent: [EdgeKey: EdgeKey], last: EdgeKey, start: Int64) -> [Int64] {
            var path = [last.to, last.from]
            var cur = last
            while let p = parent[cur] {
                path.append(p.from)
                cur = p
            }
            return path.reversed()
        }
    }
}

/// 最小限のバイナリヒープ (優先度付きキュー)。
struct BinaryHeap<Element> {
    private var items: [Element] = []
    private let less: (Element, Element) -> Bool

    init(_ less: @escaping (Element, Element) -> Bool) {
        self.less = less
    }

    mutating func push(_ x: Element) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if less(items[i], items[p]) {
                items.swapAt(i, p)
                i = p
            } else { break }
        }
    }

    mutating func pop() -> Element? {
        guard let top = items.first else { return nil }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = 2 * i + 2
            var m = i
            if l < items.count, less(items[l], items[m]) { m = l }
            if r < items.count, less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}
