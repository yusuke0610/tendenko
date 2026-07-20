import Foundation
import Network

/// MapLibre Native は style.json の tiles URL をネットワーク経由で取得する前提のため、
/// ローカルの MBTiles をオフラインのまま渡す手段として 127.0.0.1 上に最小限の HTTP
/// サーバーを立てる (完全オフライン。実際の通信は発生しない)。
/// パスは `/{z}/{x}/{y}.pbf`。
/// すべての可変状態へのアクセスは専用のシリアルキュー (`queue`) 上でのみ行う
/// (NWListener/NWConnection のコールバックは全て同じキューにディスパッチされる) ため、
/// コンパイラが検証できないだけで実際にはデータ競合しない。
public final class MBTilesServer: @unchecked Sendable {
    private let reader: MBTilesReader
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tendenko.mbtiles-server")

    /// バインドされたポート。0 を渡した場合は OS が空きポートを選ぶ。
    public private(set) var port: UInt16 = 0

    public init(mbtilesPath: String, port: UInt16 = 0) throws {
        self.reader = try MBTilesReader(path: mbtilesPath)
        let params = NWParameters.tcp
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    public func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: queue)
        // ポート確定を待つ (NWListener は start 後まもなく port が決まる)
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p != 0 {
                port = p
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw MBTilesServerError.portNotAssigned
    }

    public func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: request, on: connection)
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        guard let path = Self.parsePath(from: request), let coord = Self.parseTileCoordinate(from: path) else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", contentEncoding: nil, on: connection)
            return
        }
        let tileData: Data?
        do {
            tileData = try reader.tile(z: coord.z, x: coord.x, y: coord.y)
        } catch {
            tileData = nil
        }
        if let tileData {
            // tilemaker は tile_data を gzip 圧縮したまま MBTiles に格納する (先頭バイト 0x1f 0x8b)。
            // Content-Encoding を明示し、URLSession 側の透過的な解凍に任せる
            // (付け忘れると MapLibre が圧縮バイト列をそのまま MVT protobuf として解釈しようとし、
            // エラーにはならず単に地物 0 件の空タイルになる — ハマりどころ)。
            send(status: "200 OK", body: tileData, contentType: "application/x-protobuf",
                 contentEncoding: Self.isGzip(tileData) ? "gzip" : nil, on: connection)
        } else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", contentEncoding: nil, on: connection)
        }
    }

    private func send(status: String, body: Data, contentType: String, contentEncoding: String?, on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        if let contentEncoding {
            header += "Content-Encoding: \(contentEncoding)\r\n"
        }
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// gzip のマジックバイト (0x1f 0x8b) を持つか。tilemaker は tile_data を gzip 圧縮したまま
    /// MBTiles に格納するため、Content-Encoding を付けないと MapLibre が圧縮バイト列を
    /// そのまま MVT protobuf として解釈しようとし、エラーにはならず地物 0 件の空タイルになる。
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func parsePath(from request: String) -> String? {
        // "GET /14/14654/6242.pbf HTTP/1.1\r\n..." の 1 行目からパスを取り出す
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    static func parseTileCoordinate(from path: String) -> TileCoordinate? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let withoutExt = trimmed.hasSuffix(".pbf") ? String(trimmed.dropLast(4)) : trimmed
        let parts = withoutExt.split(separator: "/")
        guard parts.count == 3, let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else {
            return nil
        }
        return TileCoordinate(z: z, x: x, y: y)
    }
}

struct TileCoordinate: Equatable {
    let z, x, y: Int
}

public enum MBTilesServerError: Error {
    case portNotAssigned
}
