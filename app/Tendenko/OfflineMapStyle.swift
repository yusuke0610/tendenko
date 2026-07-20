import Foundation

/// ローカル MBTilesServer が配信する OpenMapTiles スキーマのベクトルタイルに対する
/// 最小の MapLibre スタイル (avoid-inundation の可視化等は後続で layer を足す)。
enum OfflineMapStyle {
    static func styleURL(serverPort: UInt16) -> URL {
        let json = styleJSON(serverPort: serverPort)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tendenko-style-\(serverPort).json")
        try? json.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func styleJSON(serverPort: UInt16) -> String {
        """
        {
          "version": 8,
          "name": "tendenko-offline",
          "sources": {
            "tendenko": {
              "type": "vector",
              "tiles": ["http://127.0.0.1:\(serverPort)/{z}/{x}/{y}.pbf"],
              "minzoom": 0,
              "maxzoom": 14
            }
          },
          "layers": [
            {"id": "background", "type": "background", "paint": {"background-color": "#eef2f5"}},
            {"id": "landuse", "type": "fill", "source": "tendenko", "source-layer": "landuse",
             "paint": {"fill-color": "#e3e8d8"}},
            {"id": "water", "type": "fill", "source": "tendenko", "source-layer": "water",
             "paint": {"fill-color": "#a9cfe3"}},
            {"id": "buildings", "type": "fill", "source": "tendenko", "source-layer": "building",
             "minzoom": 13, "paint": {"fill-color": "#d9d0c3"}},
            {"id": "roads-casing", "type": "line", "source": "tendenko", "source-layer": "transportation",
             "paint": {"line-color": "#b9c0c6", "line-width": 2.5}, "layout": {"line-cap": "round"}},
            {"id": "roads", "type": "line", "source": "tendenko", "source-layer": "transportation",
             "paint": {"line-color": "#ffffff", "line-width": 1.5}}
          ]
        }
        """
    }
}
