import Foundation
import XCTest
@testable import DoubaoClient
@testable import EnhancementPolicy

final class QwenClientTests: XCTestCase {
    private let configuration = BailianConfiguration(workspaceID: "test-workspace", region: .beijing)

    func testWorkspaceAndRegionBoundEndpoints() throws {
        let request = try QwenASRClient.request(apiKey: "test-only-key", configuration: configuration)
        XCTAssertEqual(request.url?.absoluteString, "wss://test-workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let singapore = BailianConfiguration(workspaceID: "1234", region: .singapore)
        XCTAssertEqual(try singapore.endpoint(path: "/compatible-mode/v1/systemone").host, "1234.ap-southeast-1.maas.aliyuncs.com")
        for workspace in ["", "a/b", "a.b", "test@evil", "a\nb", "中文"] {
            XCTAssertThrowsError(try BailianConfiguration(workspaceID: workspace, region: .beijing).endpoint(path: "/"))
        }
        XCTAssertThrowsError(try QwenASRClient.request(apiKey: "bad\nkey", configuration: configuration))
    }

    func testQwenNativePolishIsExplicitAndDoesNotInventITNParameters() throws {
        for enabled in [false, true] {
            let text = try QwenASRProtocol.start(taskID: "test", smoothing: enabled, language: "auto", vocabulary: [" VoiceInk ", "voiceink", "Rime"])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let payload = try XCTUnwrap(body["payload"] as? [String: Any])
            let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "qwen-audio-3.1-asr-flash-message")
            XCTAssertEqual(parameters["disfluency_removal_enabled"] as? Bool, enabled)
            XCTAssertEqual(parameters["intermediate_result_enabled"] as? Bool, true)
            XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
            XCTAssertEqual(parameters["vocabulary"] as? [String: Int], ["VoiceInk": 3, "Rime": 3])
            XCTAssertNil(parameters["language_hints"])
            XCTAssertNil(parameters["enable_itn"])
        }
    }

    func testDoubaoSemanticSmoothingIsExplicit() throws {
        for enabled in [false, true] {
            let packet = try DoubaoStreamingProtocol.configuration(smoothing: enabled)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.dropFirst(8)) as? [String: Any])
            let request = try XCTUnwrap(body["request"] as? [String: Any])
            XCTAssertEqual(request["enable_ddc"] as? Bool, enabled)
            XCTAssertEqual(request["enable_nonstream"] as? Bool, true)
        }
    }

    func testVocabularyLimitAndLanguageHint() throws {
        let text = try QwenASRProtocol.start(taskID: "test", smoothing: true, language: "zh", vocabulary: (0..<2100).map { "term\($0)" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["vocabulary"] as? [String: Int])?.count, 2000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh"])
    }

    func testTaskMismatchAndServiceFailureNeverBecomeText() {
        XCTAssertThrowsError(try QwenASRProtocol.Response.parse(Data(#"{"header":{"task_id":"other","event":"task-started"}}"#.utf8), taskID: "test"))
        XCTAssertThrowsError(try QwenASRProtocol.Response.parse(Data(#"{"header":{"task_id":"test","event":"task-failed","error_message":"private"}}"#.utf8), taskID: "test")) {
            XCTAssertEqual($0 as? QwenASRError, .service)
            XCTAssertFalse($0.localizedDescription.contains("private"))
        }
    }

    func testSentenceReplacementDeduplicationAndFinalConfirmation() async throws {
        let socket = TestQwenSocket()
        let client = QwenASRClient { _ in socket }
        try await client.connect(apiKey: "test-only-key", configuration: configuration, smoothing: true)
        try await client.sendAudioChunk(Data(repeating: 0, count: 6400))
        try await client.commit()
        var final: [String] = []
        for await text in client.finalizationEvents { final.append(text) }
        XCTAssertEqual(final, ["Hello. World."])
        let bytes = await socket.audioBytes
        XCTAssertEqual(bytes, 6400)
        await client.disconnect()
    }

    func testUnconfirmedPartialIsNotAcceptedAtTaskFinished() async throws {
        let socket = TestQwenSocket(complete: false)
        let client = QwenASRClient { _ in socket }
        try await client.connect(apiKey: "test-only-key", configuration: configuration)
        try await client.sendAudioChunk(Data(repeating: 0, count: 2))
        try await client.commit()
        var finals: [String] = []
        for await text in client.finalizationEvents { finals.append(text) }
        XCTAssertTrue(finals.isEmpty)
        var failure: QwenASRError?
        for await event in client.events { if case .error(let error) = event { failure = error } }
        XCTAssertEqual(failure, .invalidResponse)
        await client.disconnect()
    }

    func testDecisionUsesSystemOneNotChatCompletions() throws {
        let request = try BailianDecisionClient.request(text: "private transcript", instructions: "cleanup", apiKey: "test-only-key", configuration: configuration)
        XCTAssertEqual(request.url?.path, "/compatible-mode/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "decision-model-preview")
        XCTAssertNil(body["messages"])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions["needs_polish"]?["type"] as? String, "noul")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-only-key"))
    }

    func testDecisionProbabilityBoundariesAndMalformedResponses() throws {
        for (probability, expected) in [(0.0, false), (0.5, false), (0.69, false), (0.7, true), (1.0, true)] {
            let data = Data("{\"model\":\"decision-model-preview\",\"answers\":{\"needs_polish\":{\"type\":\"noul\",\"noul\":\(probability)}}}".utf8)
            XCTAssertEqual(try BailianDecisionClient.parse(data), expected)
        }
        for probability in ["true", "-0.1", "1.1", "null", "\"yes\""] {
            XCTAssertThrowsError(try BailianDecisionClient.parse(Data("{\"model\":\"decision-model-preview\",\"answers\":{\"needs_polish\":{\"type\":\"noul\",\"noul\":\(probability)}}}".utf8)))
        }
    }

    func testDecisionThresholdCanBeCustomizedForBothFormats() throws {
        for format in DecisionAPIFormat.allCases {
            let answer = format == .systemOne
                ? "{\"needs_polish\":{\"type\":\"noul\",\"noul\":0.62}}"
                : "[{\"name\":\"needs_polish\",\"type\":\"predicate\",\"probability\":0.62}]"
            let data = Data("{\"model\":\"custom\",\"answers\":\(answer)}".utf8)
            XCTAssertFalse(try BailianDecisionClient.parse(data, model: "custom", format: format))
            XCTAssertTrue(try BailianDecisionClient.parse(data, model: "custom", format: format, threshold: 0.6))
            XCTAssertTrue(try BailianDecisionClient.parse(data, model: "custom", format: format, threshold: 0.62))
            XCTAssertFalse(try BailianDecisionClient.parse(data, model: "custom", format: format, threshold: 0.8))
        }
    }

    func testDecisionSettingsValidateStoredThresholdWithoutTouchingRealPreferences() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "decision-tests-\(UUID().uuidString)"))
        XCTAssertEqual(DecisionSettings.legacyThreshold(in: defaults), 0.7)
        for value in [0.0, 0.55, 0.7, 1.0] {
            defaults.setVolatileDomain([DecisionSettings.thresholdKey: value], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(DecisionSettings.legacyThreshold(in: defaults), value)
        }
        for value: Any in [-0.1, 1.1, Double.nan, Double.infinity, "invalid", true] {
            defaults.setVolatileDomain([DecisionSettings.thresholdKey: value], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(DecisionSettings.legacyThreshold(in: defaults), DecisionSettings.defaultThreshold)
        }
    }

    func testCustomDecisionFormatsAreNotInterchangeable() throws {
        for format in DecisionAPIFormat.allCases {
            let request = try BailianDecisionClient.request(
                text: "um tomorrow tomorrow", instructions: "cleanup", apiKey: "test-only-key",
                endpoint: URL(string: "https://example.com/v1/\(format == .systemOne ? "systemone" : "decisions")")!,
                model: "custom-alias", format: format)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "custom-alias")
            if format == .systemOne {
                XCTAssertNotNil(body["state"])
                XCTAssertNil(body["input"])
                XCTAssertNotNil(body["questions"] as? [String: Any])
            } else {
                XCTAssertNotNil(body["input"] as? String)
                XCTAssertNil(body["state"])
                let questions = try XCTUnwrap(body["questions"] as? [[String: Any]])
                XCTAssertEqual(questions.first?["type"] as? String, "predicate")
            }
        }
        let response = Data(#"{"model":"resolved-alias","answers":[{"name":"needs_polish","type":"predicate","probability":0.9}]}"#.utf8)
        XCTAssertTrue(try BailianDecisionClient.parse(response, model: "custom-alias", format: .decisions))
        XCTAssertThrowsError(try BailianDecisionClient.parse(response, model: "custom-alias", format: .systemOne))
        for value in ["true", "-1", "1.1", "null", "\"yes\""] {
            let malformed = Data("{\"model\":\"custom\",\"answers\":[{\"name\":\"needs_polish\",\"type\":\"predicate\",\"probability\":\(value)}]}".utf8)
            XCTAssertThrowsError(try BailianDecisionClient.parse(malformed, model: "custom", format: .decisions))
        }
    }

    func testCustomDecisionRejectsInsecureEndpointsAndInvalidKeys() {
        for url in ["http://example.com/v1/decisions", "https://user:secret@example.com/v1/decisions", "file:///v1/systemone"] {
            XCTAssertThrowsError(try BailianDecisionClient.request(text: "test", instructions: "cleanup",
                apiKey: "test-only-key", endpoint: URL(string: url)!, model: "custom", format: .decisions))
        }
    }

    func testDoubaoSentenceAndRealtimeShareResourceButNotEndpoint() throws {
        let realtime = try DoubaoStreamingClient.makeRequest(apiKey: "test-only-key")
        let sentence = try DoubaoStreamingClient.makeRequest(apiKey: "test-only-key", sentence: true)
        XCTAssertEqual(realtime.url?.path, "/api/v3/sauc/bigmodel_async")
        XCTAssertEqual(sentence.url?.path, "/api/v3/sauc/bigmodel_nostream")
        XCTAssertEqual(sentence.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.sauc.duration")
        XCTAssertEqual(realtime.value(forHTTPHeaderField: "X-Api-Resource-Id"), sentence.value(forHTTPHeaderField: "X-Api-Resource-Id"))
    }

    func testAlwaysAndEmptyTextDoNotCallDecision() async throws {
        let always = try await EnhancementStrategy.always.decision(for: "clean text") { XCTFail("Decision must not run"); return false }
        XCTAssertEqual(always, .enhance)
        let empty = try await EnhancementStrategy.automatic.decision(for: " \n") { XCTFail("Decision must not run"); return true }
        XCTAssertEqual(empty, .unchanged)
    }

    func testAutomaticRoutingAndFailureFallsBackToPolish() async throws {
        let yes = try await EnhancementStrategy.automatic.decision(for: "um test") { true }
        let no = try await EnhancementStrategy.automatic.decision(for: "clean text") { false }
        let failure = try await EnhancementStrategy.automatic.decision(for: "clean text") { throw QwenASRError.timeout }
        XCTAssertEqual(yes, .enhance)
        XCTAssertEqual(no, .unchanged)
        XCTAssertEqual(failure, .fallback)
        XCTAssertTrue(failure.shouldEnhance)
        XCTAssertFalse(no.shouldEnhance)
        XCTAssertTrue(yes.shouldEnhance)
    }

    func testCancellationIsNotConvertedToFallback() async {
        do {
            _ = try await EnhancementStrategy.automatic.decision(for: "test") { throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor TestQwenSocket: QwenASRSocket {
    private let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    private var taskID = ""
    private let complete: Bool
    private(set) var audioBytes = 0

    init(complete: Bool = true) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incoming = stream; self.continuation = continuation; iterator = stream.makeAsyncIterator()
        self.complete = complete
    }
    func sendText(_ text: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let header = object["header"] as! [String: String]
        taskID = header["task_id"]!
        if header["action"] == "run-task" { try push("task-started") }
        else { try push("task-finished") }
    }
    func sendAudio(_ audio: Data) async throws {
        audioBytes += audio.count
        try push("result-generated", sentence: ["sentence_id": 1, "text": "draft", "sentence_end": false])
        if complete {
            try push("result-generated", sentence: ["sentence_id": 1, "text": "Hello.", "sentence_end": true])
            try push("result-generated", sentence: ["sentence_id": 1, "text": "Hello.", "sentence_end": true])
            try push("result-generated", sentence: ["sentence_id": 2, "text": "World.", "sentence_end": true])
        }
    }
    private func push(_ event: String, sentence: [String: Any]? = nil) throws {
        var object: [String: Any] = ["header": ["task_id": taskID, "event": event], "payload": [:]]
        if let sentence { object["payload"] = ["output": ["sentence": sentence]] }
        continuation.yield(try JSONSerialization.data(withJSONObject: object))
    }
    func receive() async throws -> Data {
        var iterator = iterator
        guard let data = await iterator.next() else { throw QwenASRError.network }
        self.iterator = iterator
        return data
    }
    func close() async { continuation.finish() }
}
