import Foundation
import TendenkoDomain
import TendenkoStorage

/// 1 つの地域パッケージ (`region.sqlite`) から避難経路を繰り返し引くための層 (ADR-0008)。
///
/// **読み込んだ道路グラフを保持することが唯一の存在理由。** FR-14 は逸脱から 3 秒以内の
/// リルートを求めるが、リルートのたびに SQLite からグラフと避難場所を読み直していては
/// その予算をロードだけで使い切りうる。1 度読んだら現在地を差し替えて `EvacuationRouter` を
/// 回すだけにする。
///
/// actor にしているのは、この読み込みと探索をメインスレッドから外すため。
/// `RoadGraph` は `Sendable` なので、そのまま actor の中に閉じ込められる。
actor RouteEngine {
    /// 1 回の探索結果。値だけを運ぶ (`Sendable`)。
    struct Result: Sendable, Equatable {
        let polyline: [GeoPoint]
        let inundation: [[GeoPoint]]
        let attributions: [String]
        let guidance: [GuidanceStep]
        /// 経路が見つからなければ nil
        let summary: String?
    }

    /// このエンジンが対応する `region.sqlite` のパス。差し替えは行わない (新しく作り直す)
    nonisolated let regionPath: String

    private var graph: RoadGraph?
    /// 避難場所をグラフ上の goal ノードに丸めたもの。どの避難場所に着いたかを案内文で言うために持つ
    private var sheltersByNode: [Int64: Shelter] = [:]
    /// パッケージ単位で変わらないもの。毎回作り直さない
    private var inundation: [[GeoPoint]] = []
    private var attributions: [String] = []
    private var loadFailed = false

    init(regionPath: String) {
        self.regionPath = regionPath
    }

    /// 現在地から避難場所への経路を 1 本引き、地図表示と音声案内に必要な一式を返す。
    /// パッケージを読めない場合や経路が引けない場合は nil (地図表示は継続できる)。
    func route(from origin: GeoPoint) -> Result? {
        guard let graph = loadIfNeeded(),
              let startNode = RouteGeometry.nearestNode(to: origin, in: graph)
        else { return nil }

        // 避難場所を goal ノードに丸め、最小コスト経路を 1 本求める (FR-12)
        let route = EvacuationRouter.route(graph: graph, from: startNode,
                                           goals: Set(sheltersByNode.keys))
        let destination = route?.nodeIDs.last.flatMap { sheltersByNode[$0] }
        return Result(
            polyline: route.map { RouteGeometry.polyline($0, in: graph) } ?? [],
            inundation: inundation,
            attributions: attributions,
            guidance: route.map {
                GuidanceScript.steps(for: $0, in: graph, destination: destination)
            } ?? [],
            summary: route.map { GuidanceScript.summary(for: $0, destination: destination) })
    }

    /// 初回だけ SQLite から読む。失敗したら以後は再試行しない
    /// (同じファイルに対して毎回の測位で I/O を繰り返しても結果は変わらない)。
    private func loadIfNeeded() -> RoadGraph? {
        if let graph { return graph }
        guard !loadFailed else { return nil }
        guard let loaded = try? GraphLoader.load(paths: [regionPath]),
              let shelters = try? ShelterLoader.load(paths: [regionPath])
        else {
            loadFailed = true
            return nil
        }
        var byNode: [Int64: Shelter] = [:]
        for shelter in shelters {
            guard let node = RouteGeometry.nearestNode(to: shelter.point, in: loaded) else { continue }
            byNode[node] = shelter
        }
        graph = loaded
        sheltersByNode = byNode
        inundation = RouteGeometry.inundationSegments(in: loaded)
        // 表示中パッケージの出典 (帰属表示、ADR-0002)。古いパッケージは空
        attributions = (try? MetaLoader.attributions(path: regionPath)) ?? []
        return loaded
    }
}
