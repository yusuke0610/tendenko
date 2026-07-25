import CoreLocation
import SwiftUI
import TendenkoDomain
import TendenkoStorage

// 発災時のユーザー操作はゼロが設計原則 (requirements §1)。
// この画面は最終的に「地図 + 単一経路 + 音声」だけになる。
//
// FR-02: 現在地メッシュの地域パッケージを RegionCacheCoordinator が自動 DL し、その地図を表示する。
// 配信 URL 未設定 (AppConfig.packagesBaseURL == nil) や取得失敗時は、開発用に同梱した
// 釜石メッシュ (584177) のサンプルにフォールバックして必ず地図が出るようにする。
struct ContentView: View {
    @State private var coordinator = RegionCacheCoordinator(
        baseURL: AppConfig.packagesBaseURL,
        cacheDirectory: AppConfig.cacheDirectory,
        budgetCount: AppConfig.cacheBudgetMeshes)
    @State private var mapServer: MBTilesServer?
    @State private var styleURL: URL?
    @State private var center = CLLocationCoordinate2D.kamaishi
    @State private var servedPath: String?
    @State private var loadError: String?
    @State private var routePolyline: [GeoPoint] = []
    @State private var inundationSegments: [[GeoPoint]] = []

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let styleURL {
                MapView(styleURL: styleURL, center: center, zoomLevel: 12,
                        routePolyline: routePolyline, inundationSegments: inundationSegments)
                    .ignoresSafeArea()
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
            } else {
                ProgressView("地図を読み込み中…")
            }
            // ODbL / 各データの帰属表示は常時可視にする (ADR-0002)。
            AttributionLabel()
        }
        .task {
            coordinator.start()
            await presentMap()
            await computeOverlay()
        }
        .onChange(of: coordinator.tilesPath) { _, _ in
            Task {
                await presentMap()
                await computeOverlay()
            }
        }
    }

    /// 現在地パッケージがあればそれを、無ければ同梱サンプルを配信して表示する。
    private func presentMap() async {
        let path = coordinator.tilesPath
            ?? Bundle.main.path(forResource: "tiles-584177", ofType: "mbtiles")
        guard let path else {
            loadError = "地図パッケージが見つかりません"
            return
        }
        guard path != servedPath else { return } // 同じファイルなら作り直さない

        do {
            let server = try MBTilesServer(mbtilesPath: path)
            try server.start()
            mapServer = server
            servedPath = path
            styleURL = OfflineMapStyle.styleURL(serverPort: server.port)
            if let mesh = coordinator.currentMesh {
                let c = mesh.bbox.center
                center = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
            }
        } catch {
            loadError = "地図サーバーの起動に失敗: \(error)"
        }
    }

    /// 現在地メッシュの region.sqlite から避難経路と浸水エッジを計算してオーバーレイに渡す。
    /// 読込 + 探索はバックグラウンドで行う (RoadGraph は Sendable)。結果が無ければ何もしない。
    private func computeOverlay() async {
        let regionPath = coordinator.regionPath
            ?? Bundle.main.path(forResource: "region-584177", ofType: "sqlite")
        guard let regionPath else { return }
        let start = startPoint()

        let result = await Task.detached { () -> ([GeoPoint], [[GeoPoint]])? in
            guard let graph = try? GraphLoader.load(paths: [regionPath]),
                  let shelters = try? ShelterLoader.load(paths: [regionPath]),
                  let startNode = RouteGeometry.nearestNode(to: start, in: graph)
            else { return nil }
            // 避難場所を goal ノードに丸め、最小コスト経路を 1 本求める (FR-12)
            let goals = Set(shelters.compactMap { RouteGeometry.nearestNode(to: $0.point, in: graph) })
            let route = EvacuationRouter.route(graph: graph, from: startNode, goals: goals)
            let line = route.map { RouteGeometry.polyline($0, in: graph) } ?? []
            let inundation = RouteGeometry.inundationSegments(in: graph)
            return (line, inundation)
        }.value

        if let (line, inundation) = result {
            routePolyline = line
            inundationSegments = inundation
        }
    }

    /// 経路の始点 (現在地メッシュの中心。未測位なら釜石サンプルの中心)。
    private func startPoint() -> GeoPoint {
        if let mesh = coordinator.currentMesh {
            let c = mesh.bbox.center
            return GeoPoint(lat: c.lat, lon: c.lon)
        }
        return GeoPoint(lat: 39.29, lon: 141.94)
    }
}

/// OSM (ODbL) と各データソースの帰属表示 (ADR-0002 / docs/licenses.md)。
private struct AttributionLabel: View {
    var body: some View {
        Text("© OpenStreetMap contributors ・ © 国土地理院")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
            .accessibilityLabel("地図データ © OpenStreetMap contributors、避難場所・標高 © 国土地理院")
    }
}

private extension CLLocationCoordinate2D {
    /// 釜石メッシュ (584177) の中心付近。開発用サンプルデータの表示位置。
    static let kamaishi = CLLocationCoordinate2D(latitude: 39.29, longitude: 141.94)
}
