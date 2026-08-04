import Testing

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
                                                   regionPath: nil)
        #expect(message.contains("配信URLが未設定です"))
        #expect(message.contains("サンプル"))
        #expect(message.contains("音声案内は行いません"))
    }

    @Test("実パッケージ表示中のバナーは状態だけを出す")
    func bannerPlainWithRealPackage() {
        let message = SampleFallback.bannerMessage(statusMessage: "この地域の詳細地図はまだありません",
                                                   regionPath: "/tmp/region-533946.sqlite")
        #expect(message == "この地域の詳細地図はまだありません")
    }
}
