import Testing

@testable import TendenkoDomain

@Suite("EvacuationPhase の遷移 (requirements §3.1 段階起動モデル)")
struct EvacuationPhaseTests {
    @Test("EEW で待機からウォームアップに入る")
    func eewStartsWarmup() {
        #expect(EvacuationPhase.idle.transitioned(on: .eew) == .warmup)
    }

    @Test("津波警報でウォームアップから案内に進む")
    func alertStartsGuidance() {
        #expect(EvacuationPhase.warmup.transitioned(on: .tsunamiAlert) == .guidance)
    }

    @Test("ウォームアップなしでも津波警報で案内を開始できる (手動起動含む)")
    func alertStartsGuidanceWithoutWarmup() {
        #expect(EvacuationPhase.idle.transitioned(on: .tsunamiAlert) == .guidance)
    }

    @Test("EEW が警報に至らなければウォームアップを破棄する")
    func allClearDiscardsWarmup() {
        #expect(EvacuationPhase.warmup.transitioned(on: .allClear) == .idle)
    }

    @Test("案内中の解除で終了通知に進む")
    func allClearFinishesGuidance() {
        #expect(EvacuationPhase.guidance.transitioned(on: .allClear) == .finished)
    }

    @Test("津波情報 (VTSE51) はフェーズを変えない (FR-17)")
    func tsunamiInfoKeepsPhase() {
        for phase: EvacuationPhase in [.idle, .warmup, .guidance, .finished] {
            #expect(phase.transitioned(on: .tsunamiInfo) == phase)
        }
    }

    @Test("案内中の再 EEW でウォームアップに巻き戻らない")
    func eewDuringGuidanceKeepsGuidance() {
        #expect(EvacuationPhase.guidance.transitioned(on: .eew) == .guidance)
    }
}
