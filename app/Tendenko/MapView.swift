import CoreLocation
import MapLibre
import SwiftUI

/// MLNMapView (UIKit) を SwiftUI に橋渡しする最小ラッパー。
struct MapView: UIViewRepresentable {
    let styleURL: URL
    let center: CLLocationCoordinate2D
    let zoomLevel: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)
        mapView.logoView.isHidden = true
        // ODbL 等の帰属は SwiftUI 側で常時表示するため、MapLibre 既定のボタンは隠す。
        mapView.attributionButton.isHidden = true
        context.coordinator.lastStyleURL = styleURL
        return mapView
    }

    /// スタイル URL が変わったら (= 別メッシュのパッケージに切り替わったら) 再読込して recenter する。
    /// ユーザーのパン操作と競合しないよう、同一スタイルの間は何もしない。
    func updateUIView(_ mapView: MLNMapView, context: Context) {
        guard context.coordinator.lastStyleURL != styleURL else { return }
        context.coordinator.lastStyleURL = styleURL
        mapView.styleURL = styleURL
        mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)
    }

    final class Coordinator {
        var lastStyleURL: URL?
    }
}
