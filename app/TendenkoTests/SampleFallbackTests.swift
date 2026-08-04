import Testing
import TendenkoDomain

@testable import Tendenko

/// 縮退時にサンプルの避難経路を読み上げないことを守る回帰テスト (ADR-0004 追記)。
/// `make app-test` で実行する (CI では未実行なのでローカルで回すこと)。
@Suite("SampleFallback — 同梱サンプルへのフォールバックの扱い")
struct SampleFallbackTests {

    @Test("現在地のパッケージが無く、フォールバックが有効ならサンプルを表示する")
    func presentsSampleWhenEnabled() {
        #expect(SampleFallback.shouldPresentSample(regionPath: nil, enabled: true))
    }

    @Test("フォールバックが無効ならサンプルを表示しない")
    func doesNotPresentSampleWhenDisabled() {
        #expect(!SampleFallback.shouldPresentSample(regionPath: nil, enabled: false))
    }

    @Test("現在地のパッケージがあればサンプルは使わない")
    func realPackageWins() {
        #expect(!SampleFallback.shouldPresentSample(regionPath: "/tmp/region-533946.sqlite",
                                                    enabled: true))
    }

    @Test("サンプル表示中は音声案内を行わない")
    func doesNotAnnounceSampleRoute() {
        // ここが一番落としたくない性質。サンプルの経路は現在地と無関係で、
        // 地図と違って音声は無関係な方向を断定的に指示してしまう
        #expect(!SampleFallback.shouldAnnounce(regionPath: nil))
    }

    @Test("現在地のパッケージがあるときだけ音声案内を行う")
    func announcesOnlyWithRealPackage() {
        #expect(SampleFallback.shouldAnnounce(regionPath: "/tmp/region-533946.sqlite"))
    }

    @Test("サンプル表示中のバナーはサンプルである旨と音声を出さない旨を添える")
    func bannerExplainsSample() {
        let message = SampleFallback.bannerMessage(statusMessage: "配信URLが未設定です",
                                                   regionPath: nil, enabled: true)
        #expect(message.contains("配信URLが未設定です"))
        #expect(message.contains("サンプル"))
        #expect(message.contains("音声案内は行いません"))
    }

    @Test("フォールバックが無効ならバナーはサンプルの話をしない")
    func bannerSilentAboutSampleWhenDisabled() {
        // 地図自体が出ないのに「表示中の経路はサンプルです」と言うのは嘘になる
        let message = SampleFallback.bannerMessage(statusMessage: "配信URLが未設定です",
                                                   regionPath: nil, enabled: false)
        #expect(message == "配信URLが未設定です")
    }

    @Test("実パッケージ表示中のバナーは状態だけを出す")
    func bannerPlainWithRealPackage() {
        let message = SampleFallback.bannerMessage(statusMessage: "この地域の詳細地図はまだありません",
                                                   regionPath: "/tmp/region-533946.sqlite",
                                                   enabled: true)
        #expect(message == "この地域の詳細地図はまだありません")
    }
}

@Suite("RouteOrigin — 現在地とパッケージの組み合わせ")
struct RouteOriginTests {
    private let sample = GeoPoint(lat: 39.29, lon: 141.94)
    private let tokyo = GeoPoint(lat: 35.68, lon: 139.76)

    @Test("パッケージと現在地が揃っていれば実測の現在地を使う")
    func usesLocationWhenPaired() {
        #expect(RouteOrigin.resolve(regionPath: "/tmp/region-533946.sqlite",
                                    currentLocation: tokyo, sample: sample) == tokyo)
    }

    @Test("パッケージが無ければ現在地があってもサンプルに退避する")
    func fallsBackWithoutPackage() {
        // 別地域のグラフ上で最近傍に丸められ、無関係な経路が出るのを防ぐ
        #expect(RouteOrigin.resolve(regionPath: nil, currentLocation: tokyo,
                                    sample: sample) == sample)
    }

    @Test("未測位ならサンプルに退避する")
    func fallsBackWithoutLocation() {
        #expect(RouteOrigin.resolve(regionPath: "/tmp/region-533946.sqlite",
                                    currentLocation: nil, sample: sample) == sample)
    }

    @Test("メッシュ遷移中に両方が無効化された状態でもサンプルに退避する")
    func fallsBackDuringMeshTransition() {
        // RegionCacheCoordinator はメッシュが変わると currentLocation と regionPath を
        // 同時に無効化する。その間に経路を引いても現在地は使わない
        #expect(RouteOrigin.resolve(regionPath: nil, currentLocation: nil,
                                    sample: sample) == sample)
    }
}
