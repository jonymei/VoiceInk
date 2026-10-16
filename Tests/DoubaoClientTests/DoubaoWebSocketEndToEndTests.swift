import Foundation
import XCTest
@testable import DoubaoClient

final class DoubaoWebSocketEndToEndTests: XCTestCase {
    func testNativeSocketHandshakeAudioAndFinalResultAgainstLocalServer() async throws {
        try await runRecognition(sentence: false)
    }

    func testSentenceRecognitionHandshakeAudioAndFinalResult() async throws {
        try await runRecognition(sentence: true)
    }

    private func runRecognition(sentence: Bool) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/asr_websocket_server.py")
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["uv", "run", "--no-project", fixture.path]
        server.standardOutput = output
        server.standardError = Pipe()
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let port = try XCTUnwrap(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = DoubaoStreamingClient { request in
            XCTAssertEqual(request.url?.path, sentence ? "/api/v3/sauc/bigmodel_nostream" : "/api/v3/sauc/bigmodel_async")
            var request = request
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = "ws"
            url.host = "127.0.0.1"
            url.port = port
            request.url = url.url!
            return DoubaoURLSessionSocket(request: request)
        }
        do {
            let text = try await client.transcribeFile(DoubaoClient.verificationAudio, apiKey: "test-only-key", smoothing: true, sentence: sentence)
            XCTAssertEqual(text, "Local websocket end-to-end passed.")
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }
}
