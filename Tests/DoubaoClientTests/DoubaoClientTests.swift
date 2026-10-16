import Foundation
import XCTest
@testable import DoubaoClient

final class DoubaoClientTests: XCTestCase {
    private let client = DoubaoClient()
    private let fakeKey = "test-only-not-a-real-key"

    func testRequestUsesOfficialEndpointAndNewConsoleAuthentication() throws {
        let audio = Data([1, 2, 3])
        let request = try client.makeRequest(audioData: audio, apiKey: " \(fakeKey)\n", timeout: 45)

        XCTAssertEqual(request.url?.absoluteString, "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), fakeKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Api-Request-Id"))))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Access-Key"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 45)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((body["audio"] as? [String: String])?["data"], audio.base64EncodedString())
        XCTAssertEqual((body["user"] as? [String: String])?["uid"], "voiceink")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(fakeKey))
        let options = try XCTUnwrap(body["request"] as? [String: Any])
        XCTAssertEqual(options["model_name"] as? String, "bigmodel")
        XCTAssertEqual(options["enable_itn"] as? Bool, true)
        XCTAssertEqual(options["enable_punc"] as? Bool, true)
        XCTAssertNil(options["enable_ddc"])
        XCTAssertNil(options["corpus"])
    }

    func testEachRequestHasUniqueID() throws {
        let first = try client.makeRequest(audioData: Data([1]), apiKey: fakeKey)
        let second = try client.makeRequest(audioData: Data([1]), apiKey: fakeKey)
        XCTAssertNotEqual(first.value(forHTTPHeaderField: "X-Api-Request-Id"), second.value(forHTTPHeaderField: "X-Api-Request-Id"))
    }

    func testVocabularyUsesSerializedContextAndRemovesDuplicates() throws {
        let request = try client.makeRequest(
            audioData: Data([1]), apiKey: fakeKey,
            customVocabulary: ["  VoiceInk ", "voiceink", "", "  ", "Rime", "a\"b"]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let options = try XCTUnwrap(body["request"] as? [String: Any])
        let corpus = try XCTUnwrap(options["corpus"] as? [String: String])
        let context = try XCTUnwrap(corpus["context"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: [[String: String]]])
        XCTAssertEqual(decoded["hotwords"], [["word": "VoiceInk"], ["word": "Rime"], ["word": "a\"b"]])
    }

    func testVocabularyIsLimitedToFiveThousandTerms() throws {
        let request = try client.makeRequest(
            audioData: Data([1]), apiKey: fakeKey, customVocabulary: (0..<5001).map { "term\($0)" }
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let options = try XCTUnwrap(body["request"] as? [String: Any])
        let context = try XCTUnwrap((options["corpus"] as? [String: String])?["context"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: [[String: String]]])
        XCTAssertEqual(decoded["hotwords"]?.count, 5000)
    }

    func testMissingOrMalformedKeyIsRejectedBeforeUpload() {
        for key in ["", "  \n", "key\r\nInjected: header", "key with space"] {
            XCTAssertThrowsError(try client.makeRequest(audioData: Data([1]), apiKey: key)) {
                XCTAssertEqual($0 as? DoubaoError, .missingAPIKey)
            }
        }
    }

    func testEmptyAudioIsRejectedBeforeUpload() {
        XCTAssertThrowsError(try client.makeRequest(audioData: Data(), apiKey: fakeKey)) {
            XCTAssertEqual($0 as? DoubaoError, .emptyAudio)
        }
    }

    func testOversizedAudioIsRejectedBeforeBase64Encoding() {
        XCTAssertThrowsError(try client.makeRequest(audioData: Data(count: DoubaoClient.maximumAudioBytes + 1), apiKey: fakeKey)) {
            XCTAssertEqual($0 as? DoubaoError, .audioTooLarge)
        }
    }

    func testSuccessReadsAndTrimsTranscript() throws {
        let text = try client.parseResponse(
            data: Data(#"{"result":{"text":"  VoiceInk test.  "}}"#.utf8), response: response()
        )
        XCTAssertEqual(text, "VoiceInk test.")
    }

    func testEmptyTranscriptAndSilentAudioAreNotInserted() {
        for (data, response) in [
            (Data(#"{"result":{"text":" \n "}}"#.utf8), response()),
            (Data(), response(code: "20000003")),
        ] {
            XCTAssertThrowsError(try client.parseResponse(data: data, response: response)) {
                XCTAssertEqual($0 as? DoubaoError, .noSpeech)
            }
        }
    }

    func testBusinessErrorIsRejectedEvenWhenHTTPIsSuccessful() {
        XCTAssertThrowsError(try client.parseResponse(data: Data(), response: response(code: "45000001"))) {
            XCTAssertEqual($0 as? DoubaoError, .service("45000001", logID: "test-log-id"))
        }
    }

    func testHTTPFailuresDoNotExposeServerBodyOrMessage() {
        let serverResponse = HTTPURLResponse(
            url: DoubaoClient.endpoint, statusCode: 403, httpVersion: nil,
            headerFields: ["X-Api-Message": fakeKey]
        )!
        XCTAssertThrowsError(try client.parseResponse(data: Data(fakeKey.utf8), response: serverResponse)) {
            XCTAssertEqual($0 as? DoubaoError, .http(403))
            XCTAssertFalse($0.localizedDescription.contains(self.fakeKey))
        }
    }

    func testMalformedAndUnexpectedResponsesAreRejected() {
        for body in ["not JSON", "{}", #"{"result":{}}"#, #"{"result":{"text":123}}"#] {
            XCTAssertThrowsError(try client.parseResponse(data: Data(body.utf8), response: response())) {
                XCTAssertEqual($0 as? DoubaoError, .invalidResponse)
            }
        }
        let missingStatus = HTTPURLResponse(url: DoubaoClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try client.parseResponse(data: Data(), response: missingStatus)) {
            XCTAssertEqual($0 as? DoubaoError, .invalidResponse)
        }
    }

    func testVerificationAudioIsOneSecondOfMonoSixteenKilohertzPCM() {
        let audio = DoubaoClient.verificationAudio
        XCTAssertEqual(audio.count, 32_044)
        XCTAssertEqual(String(decoding: audio[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: audio[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(Array(audio[22..<24]), [1, 0])
        XCTAssertEqual(Array(audio[24..<28]), [0x80, 0x3e, 0, 0])
        XCTAssertEqual(Array(audio[34..<36]), [16, 0])
        XCTAssertTrue(audio.dropFirst(44).allSatisfy { $0 == 0 })
    }

    private func response(code: String = "20000000") -> HTTPURLResponse {
        HTTPURLResponse(
            url: DoubaoClient.endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Api-Status-Code": code, "X-Tt-Logid": "test-log-id"]
        )!
    }
}
