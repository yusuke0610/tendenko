import CoreLocation
import SwiftUI
import TendenkoDomain
import TendenkoStorage

// 発災時のユーザー操作はゼロが設計原則 (requirements §1)。
// この画面は最終的に「地図 + 単一経路 + 音声」だけになる。
//
// 現在表示しているのは開発用のサンプルパッケージ (釜石メッシュ 584177) を同梱したもの。
// 本来は FR-02 (地域パッケージの自動ダウンロード) で取得したファイルを読む — 未実装。
struct ContentView: View {
    @State private var phase: EvacuationPhase = .idle
    @State private var mapServer: MBTilesServer?
    @State private var styleURL: URL?
    @State private var loadError: String?

    var body: some View {
        ZStack {
            if let styleURL {
                MapView(styleURL: styleURL, center: .kamaishi, zoomLevel: 12)
                    .ignoresSafeArea()
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
            } else {
                ProgressView("地図を読み込み中…")
            }
        }
        .task { startMapServerIfNeeded() }
    }

    private func startMapServerIfNeeded() {
        guard mapServer == nil else { return }
        guard let path = Bundle.main.path(forResource: "tiles-584177", ofType: "mbtiles") else {
            loadError = "サンプル地図パッケージが見つかりません"
            return
        }
        do {
            let server = try MBTilesServer(mbtilesPath: path)
            try server.start()
            mapServer = server
            styleURL = OfflineMapStyle.styleURL(serverPort: server.port)
        } catch {
            loadError = "地図サーバーの起動に失敗: \(error)"
        }
    }
}

private extension CLLocationCoordinate2D {
    /// 釜石メッシュ (584177) の中心付近。開発用サンプルデータの表示位置。
    static let kamaishi = CLLocationCoordinate2D(latitude: 39.29, longitude: 141.94)
}
