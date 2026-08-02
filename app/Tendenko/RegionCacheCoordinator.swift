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

    private let store: RegionPackageStore?
    private let budgetCount: Int
    private let locationManager = CLLocationManager()

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
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.requestWhenInUseAuthorization()
        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.requestLocation()
        status = store == nil ? .degraded("配信URLが未設定です") : .locating
    }

    // MARK: - CLLocationManagerDelegate (nonisolated → MainActor へホップ)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        Task { @MainActor in await self.handle(lat: lat, lon: lon) }
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

    private func handle(lat: Double, lon: Double) async {
        // 現在地はダウンロードの可否に関わらず常に更新する (経路の始点に使う)
        currentLocation = GeoPoint(lat: lat, lon: lon)

        let mesh = MeshCode(latitude: lat, longitude: lon)
        // メッシュが変わっていなければ (かつ取得済みなら) 何もしない
        if mesh == currentMesh, tilesPath != nil { return }
        currentMesh = mesh
        guard let store else {
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

            regionPath = await store.regionPath(for: mesh)
            tilesPath = await store.tilesPath(for: mesh)
            // manifest に無い内陸メッシュ等はパッケージが無い → 縮退 (FR-15)
            status = tilesPath != nil ? .ready : .degraded("この地域の詳細地図はまだありません")
        } catch {
            status = .degraded("地図パッケージのダウンロードに失敗しました")
        }
    }
}
