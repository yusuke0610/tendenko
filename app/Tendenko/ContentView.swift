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
    /// 案内フェーズの追従と発話 (FR-13/FR-14/FR-16、ADR-0008)
    @State private var session = GuidanceSession()
    /// 表示中パッケージの経路探索器。グラフを保持してリルートを 3 秒に収める (FR-14)
    @State private var engine: RouteEngine?
    @Environment(\.scenePhase) private var scenePhase
    /// アプリが画面に出ているか (背景に回っていないか)。
    ///
    /// **非同期の経路探索から見るのはこちらで、`scenePhase` を直接読まない。** `@Environment` は
    /// View のコピーごとの値なので、Task を作った時点のコピーに閉じ込められた古い値を返しうる。
    /// `@State` なら背景移行の反映が走行中の Task にも届く
    @State private var isVisible = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let styleURL {
                MapView(styleURL: styleURL, center: center, zoomLevel: 12,
                        routePolyline: routePolyline, inundationSegments: inundationSegments,
                        showsUserLocation: coordinator.isGuiding)
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
                    statusMessage: message, regionPath: coordinator.regionPath,
                    enabled: AppConfig.sampleFallbackEnabled))
            }
        }
        .task {
            isVisible = scenePhase != .background
            startGlyphServer()
            coordinator.start()
            await presentMap()
            await refreshRoute()
        }
        .onChange(of: coordinator.tilesPath) { _, _ in
            Task {
                await presentMap()
                await refreshRoute()
            }
        }
        .onChange(of: coordinator.currentLocation) { _, _ in
            Task { await locationChanged() }
        }
        // 案内フェーズはフォアグラウンドに閉じる (ADR-0008)。背景測位は FR-10 と一体で決める
        .onChange(of: scenePhase) { _, phase in
            guard phase != .inactive else { return } // 通知バナー等で一瞬入るだけ。追従は切らない
            isVisible = phase != .background
            guard phase == .active else {
                coordinator.endGuidance()
                return
            }
            if session.isActive, !session.hasArrived {
                coordinator.beginGuidance()
            } else if !session.hasArrived {
                // 背景にいる間に完了した探索は案内を開始していない (`startGuidance` が弾く)。
                // 復帰した今、現在地から引き直して案内に入る
                Task { await refreshRoute() }
            }
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

    /// 現在地が届いたときの分岐。
    ///
    /// **案内フェーズ中は経路を引き直さない (ADR-0008)。** 連続測位では現在地が 1Hz 級で
    /// 届くため、以前のように位置更新のたびに経路を再計算すると探索が回り続ける。
    /// 案内中の位置更新は追従に流し、経路を引き直すのは逸脱 (FR-14) のときだけにする。
    private func locationChanged() async {
        guard let location = coordinator.currentLocation else { return }
        // 到達後は引き直さない (FR-16)。避難場所に着いた人に次の経路は要らないし、
        // 避難場所を始点に引き直すと「その場から自分自身への経路」を案内し直すことになる
        guard !session.hasArrived else { return }
        guard session.isActive else {
            // 案内前。測位はパッケージ取得と独立して走るので、現在地が届いた時点で経路を引く
            await refreshRoute()
            return
        }
        let needsReroute = session.update(location: location)
        if session.hasArrived {
            // 到達したら追従は用済み。連続測位を止める (FR-16、NFR-05)
            coordinator.endGuidance()
            session.end()
            return
        }
        if needsReroute {
            await refreshRoute()
        }
    }

    /// 現在地メッシュの region.sqlite から避難経路・浸水エッジ・音声案内を計算して反映する。
    /// 初回の経路確定にもリルート (FR-14) にも同じ経路を通る — どちらも「今の現在地から引き直す」。
    private func refreshRoute() async {
        let regionPath = coordinator.regionPath ?? bundledSamplePath(resource: "region-584177",
                                                                     extension: "sqlite")
        guard let regionPath else { return }
        // パッケージが差し替わったらグラフも案内も持ち越さない (別の地域の話になる)
        if engine?.regionPath != regionPath {
            engine = RouteEngine(regionPath: regionPath)
            session.reset()
            coordinator.endGuidance()
        }
        guard let engine else { return }

        // 計算中にパッケージが変われば、この結果は古い。書き戻す前に照合する
        let requestedRegion = coordinator.regionPath
        let origin = startPoint()
        guard let result = await engine.route(from: origin) else { return }
        // 探索中にパッケージが差し替わっていたら、この経路はもう現在地のものではない。
        // 古い経路を地図に出したまま確定させると、避難中に別の場所の経路を見せることになる
        guard coordinator.regionPath == requestedRegion else { return }
        // **現在地は厳密一致で照合しない (ADR-0008)。** 連続測位では探索の間にも現在地が動くため、
        // 一致を求めると案内中のリルートがほぼ必ず破棄される。始点から大きく離れたときだけ捨てる
        if let latest = coordinator.currentLocation,
           latest.distanceM(to: origin) > Self.staleOriginToleranceM {
            return
        }

        // 経路が引けなかった結果で、案内中の経路を消さない。
        // 音声は古い経路の案内を続けているのに地図から線だけ消えると、画面と音声が食い違う
        if !result.polyline.isEmpty || !session.isActive {
            routePolyline = result.polyline
        }
        inundationSegments = result.inundation
        if !result.attributions.isEmpty { attributions = result.attributions }
        startGuidance(with: result)
    }

    /// 経路が確定したら案内フェーズに入る (ADR-0008)。
    ///
    /// 電文受信 (FR-10/FR-11) が未実装のため、案内フェーズの起点は「実データの経路が確定した瞬間」
    /// とする。境界は音声案内の可否 (`SampleFallback.shouldAnnounce`) と同じで、
    /// **同梱サンプルの経路では案内フェーズに入らない** — 現在地と無関係な経路に追従しても
    /// 意味が無く、連続測位を焚くだけになる。
    private func startGuidance(with result: RouteEngine.Result) {
        // **バックグラウンドでは案内を始めない (ADR-0008)。** 経路探索は非同期なので、
        // 画面を離れた後に完了しうる。そこで発話と連続測位を始めると、見ていない画面のために
        // GPS を焚き続けることになる (NFR-05)。フォアグラウンド復帰時に引き直す
        guard isVisible else { return }
        guard SampleFallback.shouldAnnounce(regionPath: coordinator.regionPath),
              !result.guidance.isEmpty,
              let origin = coordinator.currentLocation
        else { return }
        session.begin(polyline: result.polyline, steps: result.guidance,
                      summary: result.summary, at: origin)
        guard !session.hasArrived else { return }
        coordinator.beginGuidance()
    }

    /// 同梱サンプルのパス。フォールバックが明示的に有効なときだけ返す (AppConfig)。
    private func bundledSamplePath(resource: String, extension ext: String) -> String? {
        guard SampleFallback.shouldPresentSample(regionPath: coordinator.regionPath,
                                                 enabled: AppConfig.sampleFallbackEnabled)
        else { return nil }
        return Bundle.main.path(forResource: resource, ofType: ext)
    }

    /// 経路を引いた始点から現在地がこれ以上離れていたら、その探索結果は捨てる (m)。
    /// 徒歩なら数十秒ぶんの移動にあたり、探索 (端末内・数百ms 級) の間に超えることはまず無い
    private static let staleOriginToleranceM: Double = 50

    /// 経路の始点。判断は `RouteOrigin` に切り出してテストしている。
    private func startPoint() -> GeoPoint {
        RouteOrigin.resolve(regionPath: coordinator.regionPath,
                            currentLocation: coordinator.currentLocation,
                            sample: .kamaishiSample)
    }
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
