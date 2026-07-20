import CoreLocation
import MapLibre
import SwiftUI

/// MLNMapView (UIKit) を SwiftUI に橋渡しする最小ラッパー。
struct MapView: UIViewRepresentable {
    let styleURL: URL
    let center: CLLocationCoordinate2D
    let zoomLevel: Double

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {}
}
