import Foundation
import Testing

@testable import TendenkoStorage

@Suite("GlyphServer のパス解析 (純粋関数)")
struct GlyphServerPathParsingTests {
    @Test("フォントスタック (URLエンコード済み) とレンジをパスから取り出す")
    func parsesFontPath() {
        let result = GlyphServer.parseFontPath(from: "/fonts/Noto%20Sans%20Regular/0-255.pbf")
        #expect(result?.fontstack == "Noto Sans Regular")
        #expect(result?.range == "0-255.pbf")
    }

    @Test("不正なパスは nil")
    func rejectsInvalidPath() {
        #expect(GlyphServer.parseFontPath(from: "/not-a-font-path") == nil)
        #expect(GlyphServer.parseFontPath(from: "/fonts/OnlyOneSegment") == nil)
    }
}

@Suite("GlyphServer の HTTP 応答 (実際にソケットへ接続)")
struct GlyphServerIntegrationTests {
    @Test("存在するグリフ範囲を 200 で返し、存在しないものは 404")
    func servesGlyphRanges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glyph-test-\(UUID().uuidString)")
        let fontDir = dir.appendingPathComponent("Noto Sans Regular")
        try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("fake-glyph-pbf".utf8)
        try payload.write(to: fontDir.appendingPathComponent("0-255.pbf"))

        let server = try GlyphServer(fontsDirectory: dir.path)
        try server.start()
        defer { server.stop() }

        let (status200, body) = try await httpGet(port: server.port, path: "/fonts/Noto%20Sans%20Regular/0-255.pbf")
        #expect(status200 == 200)
        #expect(body == payload)

        let (status404, _) = try await httpGet(port: server.port, path: "/fonts/Noto%20Sans%20Regular/256-511.pbf")
        #expect(status404 == 404)

        let (statusUnknownFont, _) = try await httpGet(port: server.port, path: "/fonts/Unknown%20Font/0-255.pbf")
        #expect(statusUnknownFont == 404)
    }
}

/// GET リクエストを送り (ステータスコード, ボディ) を返す最小 HTTP クライアント。
private func httpGet(port: UInt16, path: String) async throws -> (Int, Data) {
    let (data, response) = try await URLSession.shared.data(
        for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!))
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, data)
}
