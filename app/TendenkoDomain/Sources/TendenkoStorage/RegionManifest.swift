import Foundation

/// GCS 上の manifest.json (ADR-0004) のデコード表現。
/// パイプライン (pipeline/internal/pkgwriter) が書き出す schema_version 1 に対応する。
public struct RegionManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let packages: [Package]

    public struct Package: Codable, Sendable, Equatable {
        public let mesh: String
        public let file: String
        public let bytes: Int
        public let sha256: String
        /// MBTiles を同梱するパッケージのみ (ADR-0003 追記の -tiles 生成)。
        public let tilesFile: String?
        public let tilesBytes: Int?
        public let tilesSha256: String?
    }

    /// snake_case の JSON をデコードする。未知キー (nodes/edges 等) は無視する。
    public static func decode(_ data: Data) throws -> RegionManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RegionManifest.self, from: data)
    }
}
