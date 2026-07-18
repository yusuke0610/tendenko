import Testing

@testable import Tendenko

// アプリターゲットのテスト。ドメインロジックのテストは TendenkoDomain 側に書く (swift test で高速に回る)。
struct TendenkoTests {
    @Test("アプリターゲットがテストから読み込める")
    func targetLoads() {
        #expect(Bool(true))
    }
}
