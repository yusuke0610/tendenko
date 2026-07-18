/// 受信電文 (requirements §3.2)。
public enum Telegram: Sendable, Equatable {
    /// VXSE43 / VXSE45 — 緊急地震速報
    case eew
    /// VTSE41 — 津波警報・注意報の発表
    case tsunamiAlert
    /// VTSE41 — 解除
    case allClear
    /// VTSE51 — 津波情報 (到達予想時刻の更新)
    case tsunamiInfo
}

/// 段階起動モデルのフェーズ (requirements §3.1)。
public enum EvacuationPhase: Sendable, Equatable {
    case idle
    /// BG で現在地取得・経路事前計算・「津波情報確認中」通知
    case warmup
    /// 計算済みルートで即時に音声案内・地図に単一経路を表示
    case guidance
    /// 解除後の終了通知
    case finished
}

extension EvacuationPhase {
    /// 電文受信によるフェーズ遷移。
    public func transitioned(on telegram: Telegram) -> EvacuationPhase {
        switch telegram {
        case .eew:
            switch self {
            case .idle, .finished: return .warmup
            // 案内中の再 EEW でウォームアップに戻らない
            case .warmup, .guidance: return self
            }
        case .tsunamiAlert:
            // ウォームアップを経ていなくても案内を開始できる (ETWS で気付いた手動起動を含む)
            return .guidance
        case .allClear:
            switch self {
            // EEW が警報に至らなかった場合はウォームアップを破棄
            case .warmup: return .idle
            case .guidance: return .finished
            case .idle, .finished: return self
            }
        case .tsunamiInfo:
            // 到達予想時刻の更新のみ。フェーズは変えない (FR-17)
            return self
        }
    }
}
