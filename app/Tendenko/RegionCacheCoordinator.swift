import CoreLocation
import Foundation
import Observation
import TendenkoDomain
import TendenkoStorage

/// 現在地の変化に追従して地域パッケージをローリングキャッシュする調整層 (FR-02/03、ADR-0004)。
///
/// CLLocationManager (副作用) → MeshCode / CachePlanner (純粋ドメイン) → RegionPackageStore (I/O)
/// を繋ぐ。ドメイン層とストア層はテスト済みで、ここは配線のみ。発災時の操作ゼロが原則のため
/// 起動時に自動で測位・取得を始める。
@MainActor
@Observable
final class RegionCacheCoordinator: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle
        case locating
        case downloading
        case ready
        case degraded(String)
    }

    private(set) var status: Status = .idle
    private(set) var currentMesh: MeshCode?
    /// 実測の現在地。メッシュ中心 (約 10km 四方の中心) では経路の始点として粗すぎるため別に持つ。
    private(set) var currentLocation: GeoPoint?
    /// 現在地メッシュの tiles.mbtiles のローカルパス (取得済みなら)。地図表示に使う。
    private(set) var tilesPath: String?
    /// 現在地メッシュの region.sqlite のローカルパス (取得済みなら)。経路探索に使う。
    private(set) var regionPath: String?
    /// 案内フェーズ中か (ADR-0008)。連続測位の生存区間であり、地図の現在地表示もこれに揃える
    private(set) var isGuiding = false

    private let store: RegionPackageStore?
    private let budgetCount: Int
    private let locationManager = CLLocationManager()
    /// 測位が届くたびに増える。非同期の取得完了時に「まだ最新か」を確かめるのに使う
    private var locationRevision = 0

    /// 経路の始点として受け入れる水平精度の上限 (m)。
    /// significant location change の配信は数百 m 級で届くことがあり、それを始点にすると
    /// 別の街区から案内が始まる。メッシュ判定 (約 10km 四方) には粗い測位でも足りる。
    private static let routeOriginAccuracyM: CLLocationAccuracy = 100
    /// 経路の始点として受け入れる測位の古さの上限 (秒)。キャッシュされた古い位置を掴まない
    private static let routeOriginMaxAge: TimeInterval = 120
    /// 平時の測位精度。メッシュ判定 (約 10km 四方) には粗くて足りるが、経路の始点に使うので 10m 級
    private static let plannerAccuracy: CLLocationAccuracy = kCLLocationAccuracyNearestTenMeters

    /// - Parameter baseURL: 配信ベース URL。nil なら DL せず縮退 (同梱サンプルにフォールバック)。
    init(baseURL: URL?, cacheDirectory: URL, budgetCount: Int) {
        if let baseURL {
            store = RegionPackageStore(fetcher: GCSPackageFetcher(baseURL: baseURL),
                                       cacheDirectory: cacheDirectory)
        } else {
            store = nil
        }
        self.budgetCount = budgetCount
        super.init()
        locationManager.delegate = self
    }

    /// 測位を開始する。配信 URL が設定されていればパッケージの取得も行う。
    ///
    /// **測位はダウンロードの可否と切り離す。** 配信 URL が未設定でも現在地は取得する。
    /// 現在地が分からないと「この地域の詳細地図はまだありません」(FR-15 の縮退) すら言えず、
    /// 同梱サンプルの土地にいるかのように振る舞ってしまうため。
    func start() {
        // メッシュの判定 (約 10km 四方) だけなら粗くて足りるが、経路の始点に使うので
        // 10m 級を要求する。1km 誤差の始点から探索すると別の街区から案内が始まりうる。
        // 常時 GPS ではなく requestLocation の単発測位なので NFR-05 (電池) への影響は小さい。
        locationManager.desiredAccuracy = Self.plannerAccuracy
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
        // significant location change は「移動先のパッケージを先読みする」ための常時監視 (FR-03)。
        // 先読みする配信先が無い状態で登録しても、常駐と再起動のコストだけが残る。
        // requestLocation の単発測位と違い、これはアプリを再起動させうる継続サービスである。
        if store != nil {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        status = store == nil ? .degraded("配信URLが未設定です") : .locating
    }

    // MARK: - 案内フェーズ (ADR-0008)

    /// 案内フェーズに入り、連続測位へ切り替える。
    ///
    /// NFR-05 が禁じているのは**平時**の常時 GPS であり、案内フェーズは対象外 (ADR-0008)。
    /// 有限の区間 (到達・フォアグラウンド離脱・パッケージ差し替えで終わる) に閉じることが前提。
    func beginGuidance() {
        guard !isGuiding else { return }
        isGuiding = true
        // 逸脱の許容幅は TrackingStyle.offRouteToleranceM = 40m。測位誤差がこれに迫ると
        // 経路上にいるのに逸脱と判定して誤リルートを繰り返す
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // FR-14 の 3 秒判定。距離で間引くと停止中・低速時に更新が止まる
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .fitness
        // **既定 (true) だと OS が「移動が止まった」と判断した時点で更新を止める。**
        // 避難中に無言で追従が死ぬ壊れ方を許容しない
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()
    }

    /// 案内フェーズを抜け、平時の測位に戻す。
    func endGuidance() {
        guard isGuiding else { return }
        isGuiding = false
        locationManager.stopUpdatingLocation()
        // 平時の設定に戻す (距離フィルタと自動停止は CLLocationManager の既定値)
        locationManager.desiredAccuracy = Self.plannerAccuracy
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - CLLocationManagerDelegate (nonisolated → MainActor へホップ)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let accuracyM = location.horizontalAccuracy
        let age = -location.timestamp.timeIntervalSinceNow
        Task { @MainActor in
            await self.handle(lat: lat, lon: lon, accuracyM: accuracyM, age: age)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.currentMesh == nil {
                self.status = .degraded("現在地を取得できませんでした")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        let denied = manager.authorizationStatus == .denied
            || manager.authorizationStatus == .restricted
        Task { @MainActor in
            if authorized {
                self.locationManager.requestLocation()
            } else if denied, self.currentMesh == nil {
                self.status = .degraded("位置情報の許可がありません")
            }
        }
    }

    // MARK: - 取得ロジック

    private func handle(lat: Double, lon: Double, accuracyM: CLLocationAccuracy,
                        age: TimeInterval) async {
        // horizontalAccuracy が負の測位は無効値 (CoreLocation の規約)
        guard accuracyM >= 0 else { return }

        locationRevision += 1
        let revision = locationRevision

        // 経路の始点に使えるのは、十分な精度で、かつ古すぎない測位だけ。
        // 粗い測位でもメッシュの判定 (約 10km 四方) には使えるので、そちらは下で続行する。
        let origin: GeoPoint? = (accuracyM <= Self.routeOriginAccuracyM
            && age <= Self.routeOriginMaxAge) ? GeoPoint(lat: lat, lon: lon) : nil

        let mesh = MeshCode(latitude: lat, longitude: lon)

        // **案内フェーズ中の位置更新はパッケージ取得の起点にしない (ADR-0008)。**
        // 連続測位では更新が 1Hz 級で届くため、ここから下の manifest 取得・DL 判定を
        // 通すと毎秒ネットワークを叩くことになる。追従に必要なのは現在地の更新だけ。
        // メッシュをまたいだ場合だけは通常の経路に落とし、新しい地域のパッケージへ切り替える
        if isGuiding, mesh == currentMesh {
            if let origin { currentLocation = origin }
            return
        }

        if mesh == currentMesh {
            // 同じメッシュなら、公開済みのパッケージと組み合わせて問題ない
            if let origin { currentLocation = origin }
            if tilesPath != nil { return }
        } else {
            // **メッシュが変わったら、まず公開済みのパッケージを無効化する。**
            // 新しい現在地を先に公開すると、次のパッケージが届くまでの間、
            // 旧メッシュのグラフ上で新しい現在地から経路を引いてしまう。
            // 現在地とパッケージは常に同じメッシュのものを組で公開する。
            currentMesh = mesh
            currentLocation = nil
            regionPath = nil
            tilesPath = nil
        }

        guard let store else {
            // 配信先が無い場合はパッケージと組むことがない (regionPath は常に nil) ので、
            // 現在地はそのまま公開してよい
            if let origin { currentLocation = origin }
            status = .degraded("配信URLが未設定です")
            return
        }

        status = .downloading
        do {
            try await store.refreshManifest()
            let cached = await store.cachedMeshes()
            let plan = CachePlanner.plan(current: mesh, cached: cached, budgetCount: budgetCount)
            try await store.ensure(meshes: plan.toFetch)
            await store.evict(plan.toEvict)

            // ダウンロード中に次の測位が届いていたら、この結果はもう現在地のものではない。
            // 古いメッシュのパッケージを公開すると、地図と経路が現在地とずれたまま確定する。
            guard revision == locationRevision else { return }

            regionPath = await store.regionPath(for: mesh)
            tilesPath = await store.tilesPath(for: mesh)
            // 現在地はパッケージが揃ってから公開する (上の無効化と対になる)
            if let origin { currentLocation = origin }
            // manifest に無い内陸メッシュ等はパッケージが無い → 縮退 (FR-15)
            status = tilesPath != nil ? .ready : .degraded("この地域の詳細地図はまだありません")
        } catch {
            guard revision == locationRevision else { return }
            status = .degraded("地図パッケージのダウンロードに失敗しました")
        }
    }
}
