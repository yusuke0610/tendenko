import CoreLocation
import MapLibre
import SwiftUI
import TendenkoDomain
import UIKit

/// MLNMapView (UIKit) を SwiftUI に橋渡しするラッパー。
/// ベクタタイル (ローカル MBTilesServer) の上に、避難経路 (青線) と浸水想定区域内の
/// エッジ (赤線) をオーバーレイとして描く (FR-12 の可視化)。
struct MapView: UIViewRepresentable {
    let styleURL: URL
    let center: CLLocationCoordinate2D
    let zoomLevel: Double
    var routePolyline: [GeoPoint] = []
    var inundationSegments: [[GeoPoint]] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)
        mapView.logoView.isHidden = true
        // ODbL 等の帰属は SwiftUI 側で常時表示するため、MapLibre 既定のボタンは隠す。
        mapView.attributionButton.isHidden = true
        context.coordinator.lastStyleURL = styleURL
        context.coordinator.route = routePolyline
        context.coordinator.inundation = inundationSegments
        return mapView
    }

    /// スタイル URL が変わったら (= 別メッシュのパッケージに切り替わったら) 再読込して recenter する。
    /// オーバーレイは毎回の更新で最新の経路・浸水エッジに差し替える。
    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastStyleURL != styleURL {
            coordinator.lastStyleURL = styleURL
            mapView.styleURL = styleURL
            mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)
        }
        coordinator.route = routePolyline
        coordinator.inundation = inundationSegments
        // スタイル読込済みなら即反映。未読込なら didFinishLoading で反映される。
        if let style = mapView.style {
            coordinator.apply(to: style)
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var lastStyleURL: URL?
        var route: [GeoPoint] = []
        var inundation: [[GeoPoint]] = []

        private static let routeSource = "tendenko-route-src"
        private static let routeLayer = "tendenko-route-line"
        private static let inundationSource = "tendenko-inundation-src"
        private static let inundationLayer = "tendenko-inundation-line"

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            apply(to: style)
        }

        /// 浸水エッジを先に、経路を後に足す (後から足したレイヤが上に来るので経路が最前面)。
        func apply(to style: MLNStyle) {
            applyInundation(to: style)
            applyRoute(to: style)
        }

        private func applyRoute(to style: MLNStyle) {
            replaceLayer(id: Self.routeLayer, source: Self.routeSource, in: style)
            guard route.count >= 2 else { return }
            let source = MLNShapeSource(identifier: Self.routeSource, shape: feature(route), options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: Self.routeLayer, source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            layer.lineWidth = NSExpression(forConstantValue: 5)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)
        }

        private func applyInundation(to style: MLNStyle) {
            replaceLayer(id: Self.inundationLayer, source: Self.inundationSource, in: style)
            guard !inundation.isEmpty else { return }
            let features = inundation.map { feature($0) }
            let source = MLNShapeSource(identifier: Self.inundationSource, features: features, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: Self.inundationLayer, source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor.systemRed.withAlphaComponent(0.55))
            layer.lineWidth = NSExpression(forConstantValue: 3)
            style.addLayer(layer)
        }

        private func replaceLayer(id: String, source: String, in style: MLNStyle) {
            if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
            if let src = style.source(withIdentifier: source) { style.removeSource(src) }
        }

        private func feature(_ points: [GeoPoint]) -> MLNPolylineFeature {
            var coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        }
    }
}
