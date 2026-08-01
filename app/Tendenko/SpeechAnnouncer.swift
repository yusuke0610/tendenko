import AVFoundation

// 案内文を読み上げる (FR-13、ADR-0007)。
//
// AVAudioSession は .playback / mode .voicePrompt / [.duckOthers, .interruptSpokenAudioAndMixWithOthers]。
// Apple が .voicePrompt の説明で turn-by-turn ナビの構成として名指ししている組み合わせで、
// サイレントスイッチ・画面ロック中でも鳴り、他アプリの音楽は止めずに音量を下げる。
//
// システム音量はアプリから変更できない (outputVolume は読み取り専用) ため、
// できるのはセッション内の音量を最大にするところまで。詳細と要件の緩和は ADR-0007。
//
// 発話に失敗しても地図表示は続ける (MBTilesServer/GlyphServer と同じ縮退方針)。
@MainActor
final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 渡された順に続けて読み上げる。読み上げ中に呼ぶと後ろに積まれる。
    func announce(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        activateSession()
        for text in texts {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            utterance.volume = 1.0
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    private func activateSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // セッションを取れなくても発話自体は試みる。音が出ないことは案内の劣化だが、
            // 画面まで落とす理由にはならない (ADR-0007)。
        }
    }

    /// 読み上げが終わったらセッションを解除し、他アプリの音量を元に戻す。
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // まだキューが残っていれば解除しない (区切りごとに音楽が上下しないように)
            guard !self.synthesizer.isSpeaking else { return }
            self.deactivateSession()
        }
    }
}
