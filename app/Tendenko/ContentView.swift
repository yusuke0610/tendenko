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
    @State private var glyphServer: GlyphServer?
    @State private var styleURL: URL?
    @State private var center = CLLocationCoordinate2D.kamaishi
    @State private var servedPath: String?
    @State private var loadError: String?
    @State private var routePolyline: [GeoPoint] = []
    @State private var inundationSegments: [[GeoPoint]] = []
    @State private var attributions: [String] = ["OpenStreetMap contributors", "国土地理院"]
    @State private var announcer = SpeechAnnouncer()
    /// 発話済みの案内。同じ経路で再計算が走っても読み上げ直さないためのガード
    @State private var announcedGuidance: [GuidanceStep] = []

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
            // 表示中パッケージの meta から出典を組み立てる (per-package)。
            AttributionLabel(attributions: attributions)
        }
        // 縮退している事実を隠さない。現在地が取れない・その地域のパッケージが無い、を黙って
        // サンプル表示にすり替えると、実データが出ていると誤解させる (ADR-0004 / FR-15)。
        .overlay(alignment: .top) {
            if case .degraded(let message) = coordinator.status {
                StatusBanner(message: SampleFallback.bannerMessage(
                    statusMessage: message, regionPath: coordinator.regionPath))
            }
        }
        .task {
            startGlyphServer()
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
        // 測位はパッケージ取得と独立して走るので、現在地が届いた時点でも経路を引き直す
        .onChange(of: coordinator.currentLocation) { _, _ in
            Task { await computeOverlay() }
        }
    }

    /// 地名・道路名ラベル用のフォントグリフ (Noto Sans Regular, ADR-0006) をローカル配信する。
    /// 同梱フォントが見つからない場合はラベルなしで地図自体は表示を続ける (縮退)。
    private func startGlyphServer() {
        guard let fontsDir = Bundle.main.url(forResource: "fonts", withExtension: nil) else { return }
        do {
            let server = try GlyphServer(fontsDirectory: fontsDir.path)
            try server.start()
            glyphServer = server
        } catch {
            glyphServer = nil
        }
    }

    /// 現在地パッケージがあればそれを、無ければ (明示的に許可されていれば) 同梱サンプルを配信する。
    private func presentMap() async {
        let path = coordinator.tilesPath ?? bundledSamplePath(resource: "tiles-584177",
                                                              extension: "mbtiles")
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
            styleURL = OfflineMapStyle.styleURL(serverPort: server.port, glyphPort: glyphServer?.port ?? 0)
            if let mesh = coordinator.currentMesh {
                let c = mesh.bbox.center
                center = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
            }
        } catch {
            loadError = "地図サーバーの起動に失敗: \(error)"
        }
    }

    /// 現在地メッシュの region.sqlite から避難経路・浸水エッジ・音声案内を計算する。
    /// 読込 + 探索 + 案内文生成はすべて純粋処理なのでバックグラウンドで行う (RoadGraph は Sendable)。
    private func computeOverlay() async {
        let regionPath = coordinator.regionPath ?? bundledSamplePath(resource: "region-584177",
                                                                     extension: "sqlite")
        guard let regionPath else { return }
        let start = startPoint()
        // 計算中に現在地やパッケージが変われば、この結果は古い。書き戻す前に照合する
        let requestedRegion = coordinator.regionPath
        let requestedLocation = coordinator.currentLocation

        let result = await Task.detached { () -> Overlay? in
            guard let graph = try? GraphLoader.load(paths: [regionPath]),
                  let shelters = try? ShelterLoader.load(paths: [regionPath]),
                  let startNode = RouteGeometry.nearestNode(to: start, in: graph)
            else { return nil }
            // 避難場所を goal ノードに丸め、最小コスト経路を 1 本求める (FR-12)。
            // どの避難場所に着いたかを案内文で言えるよう、丸めたノード → 避難場所も控える
            var sheltersByNode: [Int64: Shelter] = [:]
            for shelter in shelters {
                guard let node = RouteGeometry.nearestNode(to: shelter.point, in: graph) else { continue }
                sheltersByNode[node] = shelter
            }
            let route = EvacuationRouter.route(graph: graph, from: startNode,
                                               goals: Set(sheltersByNode.keys))
            let destination = route?.nodeIDs.last.flatMap { sheltersByNode[$0] }
            return Overlay(
                polyline: route.map { RouteGeometry.polyline($0, in: graph) } ?? [],
                inundation: RouteGeometry.inundationSegments(in: graph),
                // 表示中パッケージの出典 (帰属表示、ADR-0002)。古いパッケージは空。
                attributions: (try? MetaLoader.attributions(path: regionPath)) ?? [],
                guidance: route.map {
                    GuidanceScript.steps(for: $0, in: graph, destination: destination)
                } ?? [],
                summary: route.map { GuidanceScript.summary(for: $0, destination: destination) })
        }.value

        guard let result else { return }
        // 探索中に現在地やパッケージが差し替わっていたら、この経路はもう現在地のものではない。
        // 古い経路を地図に出したまま確定させると、避難中に別の場所の経路を見せることになる
        guard coordinator.regionPath == requestedRegion,
              coordinator.currentLocation == requestedLocation
        else { return }
        routePolyline = result.polyline
        inundationSegments = result.inundation
        if !result.attributions.isEmpty { attributions = result.attributions }
        announce(result)
    }

    /// 経路が確定したら概要と最初の指示を読み上げる (FR-13)。
    /// 位置に追従して残りを順次読み上げるのは FR-14/FR-16 と合わせて実装する。
    private func announce(_ overlay: Overlay) {
        // 同梱サンプルの経路は現在地と無関係なので読み上げない (SampleFallback 参照)
        guard SampleFallback.shouldAnnounce(regionPath: coordinator.regionPath) else { return }
        guard !overlay.guidance.isEmpty, overlay.guidance != announcedGuidance else { return }
        announcedGuidance = overlay.guidance
        let opening = overlay.summary.map { [$0] } ?? []
        announcer.announce(opening + overlay.guidance.prefix(2).map(\.text))
    }

    /// 同梱サンプルのパス。フォールバックが明示的に有効なときだけ返す (AppConfig)。
    private func bundledSamplePath(resource: String, extension ext: String) -> String? {
        guard SampleFallback.shouldPresentSample(regionPath: coordinator.regionPath,
                                                 enabled: AppConfig.sampleFallbackEnabled)
        else { return nil }
        return Bundle.main.path(forResource: resource, ofType: ext)
    }

    /// 経路の始点。
    ///
    /// 現在地を使えるのは、その現在地を含む地域パッケージを実際に読み込めているときだけ。
    /// 同梱サンプル (釜石) にフォールバックしている状態で実際の現在地から探索すると、
    /// グラフ上の最近傍ノードが釜石のどこかに丸められ、まったく無関係な経路が出てしまう。
    /// パッケージが無い地域では現在地を捨ててサンプルの土地を案内する — 実データが来るまでの
    /// デモであることを崩さないための割り切りで、本来は FR-15 の縮退モードに入るべき場面。
    private func startPoint() -> GeoPoint {
        guard coordinator.regionPath != nil, let location = coordinator.currentLocation else {
            return .kamaishiSample
        }
        return location
    }
}

/// バックグラウンドで計算した表示・発話用の一式。純粋な値だけを運ぶ (Sendable)。
private struct Overlay: Sendable {
    let polyline: [GeoPoint]
    let inundation: [[GeoPoint]]
    let attributions: [String]
    let guidance: [GuidanceStep]
    /// 経路が見つからなければ nil
    let summary: String?
}

/// 縮退状態 (現在地が取れない・配信 URL 未設定・その地域のパッケージが無い) の告知。
private struct StatusBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}

/// OSM (ODbL) と各データソースの帰属表示 (ADR-0002 / docs/licenses.md)。
/// 表示中パッケージの出典に応じて per-package で内容が変わる (福井県データ表示時は「© 福井県」等)。
private struct AttributionLabel: View {
    let attributions: [String]

    private var text: String {
        attributions.map { "© \($0)" }.joined(separator: " ・ ")
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
            .accessibilityLabel("地図データの出典: " + attributions.joined(separator: "、"))
    }
}

private extension CLLocationCoordinate2D {
    /// 釜石メッシュ (584177) の中心付近。開発用サンプルデータの表示位置。
    static let kamaishi = CLLocationCoordinate2D(latitude: 39.29, longitude: 141.94)
}

private extension GeoPoint {
    /// 同梱サンプル (釜石 584177) の想定現在地。配信 URL 未設定時のデモ用。
    static let kamaishiSample = GeoPoint(lat: 39.29, lon: 141.94)
}
