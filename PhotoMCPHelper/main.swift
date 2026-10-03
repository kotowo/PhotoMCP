import Foundation
import MCP

// 重要: StdioTransportは標準出力(stdout)をMCPプロトコル通信に使う。
// このプロセスからのデバッグ出力は絶対にstdoutへ書かないこと（プロトコルが壊れる）。
// 診断ログは必ず標準エラー(stderr)へ。
func debugLog(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

debugLog("[PhotoMCPHelper] starting...")

let server = Server(
    name: "PhotoMCP",
    version: "0.1.1",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await registerHandlers(on: server)

let transport = StdioTransport()
do {
    try await server.start(transport: transport)
    debugLog("[PhotoMCPHelper] MCP server started, waiting for requests...")
} catch {
    debugLog("[PhotoMCPHelper] failed to start: \(error)")
    exit(1)
}

// Claude Desktopがstdioを閉じる（プロセス終了）までブロックし続ける。
try await Task.sleep(for: .seconds(60 * 60 * 24 * 36500))  // .days は Duration に存在しないため秒に換算
