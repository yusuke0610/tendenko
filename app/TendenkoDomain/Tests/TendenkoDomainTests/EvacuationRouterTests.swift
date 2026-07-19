import Testing

@testable import TendenkoDomain

/// 格子状の合成グラフでルーターの性質を検証する。座標は探索に使われないためダミー。
private func makeGraph(_ edges: [UndirectedEdge]) -> RoadGraph {
    var nodes: [Int64: GraphNode] = [:]
    for e in edges {
        nodes[e.from] = GraphNode(lat: 0, lon: 0, elevM: nil)
        nodes[e.to] = GraphNode(lat: 0, lon: 0, elevM: nil)
    }
    return RoadGraph(nodes: nodes, undirectedEdges: edges)
}

private func edge(_ from: Int64, _ to: Int64, _ lengthM: Double,
                  grade: Double = 0, bearing: Double = 0, flags: EdgeFlags = []) -> UndirectedEdge {
    UndirectedEdge(from: from, to: to, lengthM: lengthM, grade: grade, bearingDeg: bearing, flags: flags)
}

@Suite("EvacuationRouter (FR-12: 浸水リスク最小 + 迷いにくさ)")
struct EvacuationRouterTests {
    @Test("単純な 2 ホップ経路を距離どおりに返す")
    func simplePath() {
        let g = makeGraph([edge(1, 2, 100), edge(2, 3, 200)])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [3])
        #expect(r?.nodeIDs == [1, 2, 3])
        #expect(r?.lengthM == 300)
    }

    @Test("始点が目的地なら空移動の経路")
    func startIsGoal() {
        let g = makeGraph([edge(1, 2, 100)])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [1])
        #expect(r == Route(nodeIDs: [1], cost: 0, lengthM: 0))
    }

    @Test("到達不能なら nil")
    func unreachable() {
        let g = makeGraph([edge(1, 2, 100), edge(3, 4, 100)])
        #expect(EvacuationRouter.route(graph: g, from: 1, goals: [4]) == nil)
    }

    @Test("浸水想定区域を迂回する (直進 100m 浸水 vs 迂回 150m)")
    func avoidsInundation() {
        let g = makeGraph([
            edge(1, 3, 100, flags: [.inundation]),
            edge(1, 2, 75), edge(2, 3, 75),
        ])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [3])
        #expect(r?.nodeIDs == [1, 2, 3])
    }

    @Test("重みをゼロにすれば最短距離に戻る (重みがチューニング可能であること)")
    func tunableWeights() {
        let g = makeGraph([
            edge(1, 3, 100, flags: [.inundation]),
            edge(1, 2, 75), edge(2, 3, 75),
        ])
        var m = CostModel()
        m.inundationFactor = 1.0
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [3], cost: m)
        #expect(r?.nodeIDs == [1, 3])
    }

    @Test("同距離なら下りより登りを選ぶ (低い方へ向かう経路を罰する)")
    func prefersUphill() {
        let g = makeGraph([
            edge(1, 2, 100, grade: -0.10), edge(2, 4, 100, grade: -0.10), // 下って回る
            edge(1, 3, 100, grade: +0.10), edge(3, 4, 100, grade: +0.10), // 登って回る
        ])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [4])
        #expect(r?.nodeIDs == [1, 3, 4])
    }

    @Test("同距離なら曲がりの少ない経路を選ぶ")
    func prefersFewerTurns() {
        let g = makeGraph([
            // 直進ルート: bearing 0 → 0
            edge(1, 2, 100, bearing: 0), edge(2, 5, 100, bearing: 0),
            // ジグザグルート: bearing 90 → 0 → 270 (2 回転換)
            edge(1, 3, 60, bearing: 90), edge(3, 4, 80, bearing: 0), edge(4, 5, 60, bearing: 270),
        ])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [5])
        #expect(r?.nodeIDs == [1, 2, 5])
    }

    @Test("複数目的地から近い方を選ぶ")
    func multipleGoals() {
        let g = makeGraph([edge(1, 2, 100), edge(2, 3, 100), edge(1, 4, 50)])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [3, 4])
        #expect(r?.nodeIDs == [1, 4])
    }

    @Test("私道は実質通らない (代替があれば大回りでも公道)")
    func avoidsPrivate() {
        let g = makeGraph([
            edge(1, 2, 100, flags: [.privateAccess]),
            edge(1, 3, 300), edge(3, 2, 300),
        ])
        let r = EvacuationRouter.route(graph: g, from: 1, goals: [2])
        #expect(r?.nodeIDs == [1, 3, 2])
    }
}
