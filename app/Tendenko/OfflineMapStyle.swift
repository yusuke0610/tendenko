import Foundation

/// ローカル MBTilesServer が配信する OpenMapTiles スキーマのベクトルタイルに対する
/// 最小の MapLibre スタイル。地名・道路名ラベルは ADR-0006 (Noto Sans Regular を同梱し
/// GlyphServer でローカル配信、`glyphs` にその URL を渡す)。
/// タイルのプロパティ名は tilemaker 既定の process-openmaptiles.lua の設定 (preferred_language
/// 未設定) により、実際の地名は `name` ではなく `name:latin` キーに入る (実タイルをデコードして確認済み)。
enum OfflineMapStyle {
    static func styleURL(serverPort: UInt16, glyphPort: UInt16) -> URL {
        let json = styleJSON(serverPort: serverPort, glyphPort: glyphPort)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendenko-style-\(serverPort)-\(glyphPort).json")
        try? json.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func styleJSON(serverPort: UInt16, glyphPort: UInt16) -> String {
        """
        {
          "version": 8,
          "name": "tendenko-offline",
          "glyphs": "http://127.0.0.1:\(glyphPort)/fonts/{fontstack}/{range}.pbf",
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
             "paint": {"line-color": "#ffffff", "line-width": 1.5}},
            {"id": "road-name", "type": "symbol", "source": "tendenko", "source-layer": "transportation_name",
             "minzoom": 12,
             "layout": {
               "text-field": ["get", "name:latin"], "text-font": ["Noto Sans Regular"],
               "symbol-placement": "line", "text-size": 11
             },
             "paint": {"text-color": "#5b5f63", "text-halo-color": "#eef2f5", "text-halo-width": 1.2}},
            {"id": "place-label", "type": "symbol", "source": "tendenko", "source-layer": "place",
             "layout": {
               "text-field": ["get", "name:latin"], "text-font": ["Noto Sans Regular"],
               "text-size": ["interpolate", ["linear"], ["zoom"], 8, 10, 14, 14]
             },
             "paint": {"text-color": "#33383b", "text-halo-color": "#eef2f5", "text-halo-width": 1.2}}
          ]
        }
        """
    }
}
