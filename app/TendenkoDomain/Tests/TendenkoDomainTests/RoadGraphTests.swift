import Testing

@testable import TendenkoDomain

@Suite("RoadGraph の双方向展開 (ADR-0003)")
struct RoadGraphTests {
    @Test("無向エッジから逆向きが導出される (grade 反転・bearing 180° 回転)")
    func expandsReverseEdge() {
        let nodes: [Int64: GraphNode] = [
            1: GraphNode(lat: 39.25, lon: 141.90, elevM: 10),
            2: GraphNode(lat: 39.26, lon: 141.90, elevM: 30),
        ]
        let g = RoadGraph(nodes: nodes, undirectedEdges: [
            UndirectedEdge(from: 1, to: 2, lengthM: 1000, grade: 0.02, bearingDeg: 350, flags: [.bridge])
        ])

        let forward = g.adjacency[1]!
        #expect(forward == [DirectedEdge(to: 2, lengthM: 1000, grade: 0.02, bearingDeg: 350, flags: [.bridge])])

        let backward = g.adjacency[2]!
        #expect(backward.count == 1)
        #expect(backward[0].to == 1)
        #expect(backward[0].grade == -0.02)
        #expect(backward[0].bearingDeg == 170) // (350 + 180) mod 360
        #expect(backward[0].flags == [.bridge])
    }
}
