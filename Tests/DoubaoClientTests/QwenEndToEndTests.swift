import Foundation
import XCTest
@testable import DoubaoClient
@testable import EnhancementPolicy

final class QwenEndToEndTests: XCTestCase {
    func testNativeWebSocketBuiltInCleanupAndOptionalDecisionRouting() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/qwen_websocket_server.py")
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["uv", "run", "--no-project", fixture.path]
        server.standardOutput = output; server.standardError = Pipe()
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = QwenASRClient { request in
            var request = request
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = "ws"; url.host = "127.0.0.1"; url.port = port
            request.url = url.url!
            return QwenURLSessionSocket(request: request)
        }
        do {
            let text = try await client.transcribeFile(
                DoubaoClient.verificationAudio, apiKey: "test-only-key",
                configuration: .init(workspaceID: "test", region: .beijing), smoothing: true, language: "en", vocabulary: []
            )
            XCTAssertEqual(text, "Clean ASR result.")
            let decision = try await EnhancementStrategy.automatic.decision(for: text) {
                try BailianDecisionClient.parse(Data(#"{"model":"decision-model-preview","answers":{"needs_polish":{"type":"noul","noul":0.02}}}"#.utf8))
            }
            XCTAssertEqual(decision, .unchanged)
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }
}

final class BailianDecisionIntegrationTests: XCTestCase {
    override func tearDown() { DecisionStub.handler = nil; super.tearDown() }

    func testCustomProtocolsHTTPRoundTrip() async throws {
        for format in DecisionAPIFormat.allCases {
            for probability in [0.1, 0.9] {
                DecisionStub.handler = { request in
                    XCTAssertEqual(request.url?.path, format == .systemOne ? "/v1/systemone" : "/v1/decisions")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
                    let answer = format == .systemOne
                        ? "{\"needs_polish\":{\"type\":\"noul\",\"noul\":\(probability)}}"
                        : "[{\"name\":\"needs_polish\",\"type\":\"predicate\",\"probability\":\(probability)}]"
                    return (200, Data("{\"model\":\"resolved\",\"answers\":\(answer)}".utf8))
                }
                let decision = try await EnhancementStrategy.automatic.decision(for: "test") {
                    try await self.makeClient().needsPolish(text: "test", instructions: "cleanup", apiKey: "test-only-key",
                        endpoint: URL(string: "https://example.com/v1/\(format == .systemOne ? "systemone" : "decisions")")!,
                        model: "custom-alias", format: format, threshold: DecisionSettings.defaultThreshold)
                }
                XCTAssertEqual(decision, probability < DecisionSettings.defaultThreshold ? .unchanged : .enhance)
            }
        }
    }

    func testDecisionDevelopmentLogsAndFallbackRouting() async throws {
        let directory = TestDirectories.unique("decision-logs")
        let log = DevelopmentDecisionLog(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecisionStub.self]
        let client = BailianDecisionClient(session: URLSession(configuration: configuration), developmentLog: log)
        let transcript = "um\nmeet tomorrow tomorrow"
        log.record("asr_result", fields: ["raw_text": transcript, "model": "test-asr"])
        for format in DecisionAPIFormat.allCases {
            DecisionStub.handler = { _ in
                let answer = format == .systemOne
                    ? "{\"needs_polish\":{\"type\":\"noul\",\"noul\":0.75}}"
                    : "[{\"name\":\"needs_polish\",\"type\":\"predicate\",\"probability\":0.75}]"
                return (200, Data("{\"model\":\"custom\",\"answers\":\(answer)}".utf8))
            }
            let needsPolish = try await client.needsPolish(text: transcript, instructions: "cleanup",
                apiKey: "test-secret-must-not-appear", endpoint: URL(string: "https://example.com/v1/decisions")!,
                model: "custom", format: format, threshold: DecisionSettings.defaultThreshold)
            XCTAssertTrue(needsPolish)
        }
        DecisionStub.handler = { _ in (401, Data("private server body".utf8)) }
        let route = try await EnhancementStrategy.automatic.decision(for: transcript) {
            try await client.needsPolish(text: transcript, instructions: "cleanup", apiKey: "test-secret-must-not-appear",
                endpoint: URL(string: "https://example.com/v1/decisions")!, model: "custom", format: .decisions,
                threshold: DecisionSettings.defaultThreshold)
        }
        XCTAssertEqual(route, .fallback)
        XCTAssertTrue(route.shouldEnhance)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("test-secret-must-not-appear"))
        XCTAssertFalse(contents.contains("private server body"))
        let entries = try contents.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0]["raw_text"] as? String, transcript)
        XCTAssertEqual(entries[1]["probability"] as? Double, 0.75)
        XCTAssertEqual(entries[1]["threshold"] as? Double, DecisionSettings.defaultThreshold)
        XCTAssertEqual(entries[2]["need_polish"] as? Bool, true)
        XCTAssertNotNil(entries[1]["questions"])
        XCTAssertEqual(entries[3]["status"] as? String, "unavailable")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDecisionHTTPRoundTripAndRouting() async throws {
        for probability in [0.01, 0.99] {
            DecisionStub.handler = { request in
                XCTAssertEqual(request.url?.path, "/compatible-mode/v1/systemone")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
                return (200, Data("{\"model\":\"decision-model-preview\",\"answers\":{\"needs_polish\":{\"type\":\"noul\",\"noul\":\(probability)}}}".utf8))
            }
            let client = makeClient()
            let decision = try await EnhancementStrategy.automatic.decision(for: "ASR output") {
                try await client.needsPolish(text: "ASR output", instructions: "cleanup", apiKey: "test-only-key",
                                             configuration: .init(workspaceID: "test", region: .beijing),
                                             threshold: DecisionSettings.defaultThreshold)
            }
            XCTAssertEqual(decision, probability < DecisionSettings.defaultThreshold ? .unchanged : .enhance)
        }
    }

    func testDecisionHTTPFailuresAreSanitizedAndFallBackToPolish() async throws {
        for status in [401, 403, 429, 500] {
            DecisionStub.handler = { _ in (status, Data("sensitive server body".utf8)) }
            let client = makeClient()
            do {
                _ = try await client.needsPolish(text: "test", instructions: "cleanup", apiKey: "test-only-key",
                                                 configuration: .init(workspaceID: "test", region: .beijing),
                                                 threshold: DecisionSettings.defaultThreshold)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? QwenASRError, .http(status))
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            }
            let decision = try await EnhancementStrategy.automatic.decision(for: "test") {
                try await client.needsPolish(text: "test", instructions: "cleanup", apiKey: "test-only-key",
                                             configuration: .init(workspaceID: "test", region: .beijing),
                                             threshold: DecisionSettings.defaultThreshold)
            }
            XCTAssertEqual(decision, .fallback)
        }
    }

    func testDecisionTimeoutAndMalformedSuccessFallBackToPolish() async throws {
        let client = makeClient()
        DecisionStub.handler = { _ in throw URLError(.timedOut) }
        let timeout = try await EnhancementStrategy.automatic.decision(for: "test") {
            try await client.needsPolish(text: "test", instructions: "cleanup", apiKey: "test-only-key",
                                         configuration: .init(workspaceID: "test", region: .beijing),
                                         threshold: DecisionSettings.defaultThreshold)
        }
        XCTAssertEqual(timeout, .fallback)
        DecisionStub.handler = { _ in (200, Data("{}".utf8)) }
        let malformed = try await EnhancementStrategy.automatic.decision(for: "test") {
            try await client.needsPolish(text: "test", instructions: "cleanup", apiKey: "test-only-key",
                                         configuration: .init(workspaceID: "test", region: .beijing),
                                         threshold: DecisionSettings.defaultThreshold)
        }
        XCTAssertEqual(malformed, .fallback)
    }

    private func makeClient() -> BailianDecisionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecisionStub.self]
        let directory = TestDirectories.unique("decision-logs")
        return BailianDecisionClient(session: URLSession(configuration: configuration),
                                     developmentLog: DevelopmentDecisionLog(directory: directory))
    }
}

private final class DecisionStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
