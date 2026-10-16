import Foundation
import XCTest
@testable import DoubaoClient
@testable import EnhancementPolicy

@MainActor
final class ParallelPolishEndToEndTests: XCTestCase {
    func testNegativeDecisionReturnsOriginalBeforeServerReleasesPolish() async throws {
        try await runScenario("decline", format: .systemOne, threshold: 0.7, expected: nil)
    }

    func testPositiveDecisionUsesConcurrentPolish() async throws {
        try await runScenario("accept", format: .systemOne, threshold: 0.7, expected: "polished text")
    }

    func testCustomThresholdAndDecisionsFormatUseConcurrentPolish() async throws {
        try await runScenario("custom", format: .decisions, threshold: 0.6, expected: "polished text")
    }

    func testPolishReturnsBeforeServerReleasesNegativeDecision() async throws {
        try await runScenario("polish-first", format: .systemOne, threshold: 0.7, expected: "polished text")
    }

    private func runScenario(_ transcript: String, format: DecisionAPIFormat,
                             threshold: Double, expected: String?) async throws {
        let server = Process()
        let output = Pipe()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parallel_polish_server.py")
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["uv", "run", "--no-project", fixture.path]
        server.standardOutput = output
        server.standardError = Pipe()
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let decisionEndpoint = URL(string: "https://127.0.0.1:\(port)/\(format == .systemOne ? "systemone" : "decisions")")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopbackDecisionProtocol.self]
        let decisionSession = URLSession(configuration: configuration)
        let polishSession = URLSession(configuration: .ephemeral)
        defer {
            decisionSession.invalidateAndCancel()
            polishSession.invalidateAndCancel()
        }
        let directory = TestDirectories.unique("parallel-polish")
        let client = BailianDecisionClient(session: decisionSession, developmentLog: DevelopmentDecisionLog(directory: directory))
        let started = ContinuousClock.now
        var routes: [EnhancementStrategy.Decision] = []
        let result = try await EnhancementStrategy.automatic.process(
            for: transcript,
            decide: {
                try await client.needsPolish(text: transcript, instructions: "cleanup", apiKey: "test-only-key",
                    endpoint: decisionEndpoint, model: "custom", format: format, threshold: threshold)
            },
            enhance: {
                var request = URLRequest(url: base.appendingPathComponent("polish"), timeoutInterval: 8)
                request.httpMethod = "POST"
                request.setValue("Bearer test-only-key", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["transcript": transcript])
                let (data, response) = try await polishSession.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: String])?["text"])
            },
            onDecision: { route in
                routes.append(route)
                if route == .enhance || route == .fallback {
                    Task { _ = try await polishSession.data(from: base.appendingPathComponent("release")) }
                }
            }
        )
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(result, expected)
        if transcript == "polish-first" {
            XCTAssertLessThan(elapsed, .seconds(2), "Do not wait for the blocked decision response")
            XCTAssertEqual(routes, [.polishFirst])
            let (state, _) = try await polishSession.data(from: base.appendingPathComponent("state"))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Bool])
            XCTAssertEqual(fields["decision_released"], false)
            _ = try await polishSession.data(from: base.appendingPathComponent("release-decision"))
            return
        }
        if expected == nil {
            XCTAssertLessThan(elapsed, .seconds(2), "Do not wait for the blocked polish response")
            _ = try await polishSession.data(from: base.appendingPathComponent("release"))
        }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.last).utf8)) as? [String: Any])
        XCTAssertEqual(entry["threshold"] as? Double, threshold)
        XCTAssertEqual(entry["need_polish"] as? Bool, expected != nil)
    }
}

// Keep production HTTPS validation; only the test transport forwards to the loopback HTTP fixture.
private final class LoopbackDecisionProtocol: URLProtocol {
    private var forwardingTask: URLSessionDataTask?
    private var session: URLSession?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" && request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var forwarded = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "http"
        forwarded.url = url.url!
        session = URLSession(configuration: .ephemeral)
        forwardingTask = session!.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else if let data, let response = response as? HTTPURLResponse {
                let original = HTTPURLResponse(url: self.request.url!, statusCode: response.statusCode,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: original, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            self.session?.finishTasksAndInvalidate()
        }
        forwardingTask!.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        session?.invalidateAndCancel()
    }
}
