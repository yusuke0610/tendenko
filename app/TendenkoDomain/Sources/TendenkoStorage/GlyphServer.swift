import Foundation
import Network

/// MapLibre のスタイル JSON は `glyphs` にテキストラベル描画用フォントグリフの URL テンプレート
/// (`{fontstack}/{range}.pbf`) を要求する。オフラインアプリのためネットワーク越しには取得できず、
/// アプリに同梱したグリフ PBF (Noto Sans Regular、ADR-0006) を 127.0.0.1 でローカル配信する。
/// `MBTilesServer` と同じ NWListener パターン。
/// パスは `/fonts/{fontstack}/{range}.pbf` (fontstack はパーセントエンコード、例: "Noto%20Sans%20Regular")。
public final class GlyphServer: @unchecked Sendable {
    private let fontsDirectory: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tendenko.glyph-server")

    /// バインドされたポート。0 を渡した場合は OS が空きポートを選ぶ。
    public private(set) var port: UInt16 = 0

    public init(fontsDirectory: String, port: UInt16 = 0) throws {
        self.fontsDirectory = fontsDirectory
        let params = NWParameters.tcp
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    public func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: queue)
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p != 0 {
                port = p
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw GlyphServerError.portNotAssigned
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
        guard let path = MBTilesServer.parsePath(from: request),
              let font = Self.parseFontPath(from: path)
        else {
            send(status: "400 Bad Request", body: Data(), on: connection)
            return
        }
        let filePath = (fontsDirectory as NSString)
            .appendingPathComponent(font.fontstack)
            .appending("/" + font.range)
        if let body = FileManager.default.contents(atPath: filePath) {
            send(status: "200 OK", body: body, on: connection)
        } else {
            send(status: "404 Not Found", body: Data(), on: connection)
        }
    }

    private func send(status: String, body: Data, on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/x-protobuf\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// `/fonts/{fontstack}/{range}.pbf` からフォントスタック名 (パーセントデコード済み) とレンジファイル名を取り出す。
    static func parseFontPath(from path: String) -> (fontstack: String, range: String)? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "fonts", parts[2].hasSuffix(".pbf") else { return nil }
        guard let fontstack = String(parts[1]).removingPercentEncoding else { return nil }
        return (fontstack, String(parts[2]))
    }
}

public enum GlyphServerError: Error {
    case portNotAssigned
}
