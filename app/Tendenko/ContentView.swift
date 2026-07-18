import SwiftUI
import TendenkoDomain

// 発災時のユーザー操作はゼロが設計原則 (requirements §1)。
// この画面は最終的に「地図 + 単一経路 + 音声」だけになる。
struct ContentView: View {
    @State private var phase: EvacuationPhase = .idle

    var body: some View {
        VStack(spacing: 12) {
            Text("tendenko")
                .font(.largeTitle.bold())
            Text("地図 (MapLibre) は未実装")
                .foregroundStyle(.secondary)
            Text("phase: \(String(describing: phase))")
                .font(.footnote.monospaced())
        }
    }
}
