import Foundation
import XCTest
@testable import DoubaoClient

final class DoubaoHTTPIntegrationTests: XCTestCase {
    override func tearDown() {
        StubSpeechProtocol.handler = nil
        super.tearDown()
    }

    func testAudioUploadToTranscriptRoundTrip() async throws {
        let audio = DoubaoClient.verificationAudio
        StubSpeechProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "test-only-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.readBody(request)) as? [String: Any])
            let uploaded = try XCTUnwrap((body["audio"] as? [String: String])?["data"])
            XCTAssertEqual(Data(base64Encoded: uploaded), audio)
            return (200, ["X-Api-Status-Code": "20000000"], Data(#"{"result":{"text":"Round trip complete."}}"#.utf8))
        }
        let text = try await makeClient().transcribe(audioData: audio, apiKey: "test-only-key")
        XCTAssertEqual(text, "Round trip complete.")
    }

    func testVerificationAcceptsAuthenticatedSilence() async {
        StubSpeechProtocol.handler = { request in
            XCTAssertEqual(request.timeoutInterval, 30)
            return (200, ["X-Api-Status-Code": "20000003"], Data())
        }
        let result = await makeClient().verifyAPIKey("test-only-key")
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.errorMessage)
    }

    func testVerificationAcceptsSuccessfulEmptyTranscript() async {
        StubSpeechProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "20000000"], Data(#"{"result":{"text":""}}"#.utf8))
        }
        let result = await makeClient().verifyAPIKey("test-only-key")
        XCTAssertTrue(result.isValid)
    }

    func testVerificationRejectsAuthenticationAndServiceErrors() async {
        for status in [401, 403, 429, 500] {
            StubSpeechProtocol.handler = { _ in (status, [:], Data("must not be exposed".utf8)) }
            let result = await makeClient().verifyAPIKey("test-only-key")
            XCTAssertFalse(result.isValid)
            XCTAssertNotNil(result.errorMessage)
            XCTAssertFalse(result.errorMessage!.contains("must not be exposed"))
        }
        StubSpeechProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "45000001"], Data())
        }
        let result = await makeClient().verifyAPIKey("test-only-key")
        XCTAssertFalse(result.isValid)
    }

    func testVerificationRejectsMalformedSuccess() async {
        StubSpeechProtocol.handler = { _ in (200, ["X-Api-Status-Code": "20000000"], Data("{}".utf8)) }
        let result = await makeClient().verifyAPIKey("test-only-key")
        XCTAssertFalse(result.isValid)
    }

    func testNetworkFailureIsNotTreatedAsValidCredentials() async {
        StubSpeechProtocol.handler = { _ in throw URLError(.timedOut) }
        let result = await makeClient().verifyAPIKey("test-only-key")
        XCTAssertFalse(result.isValid)
        XCTAssertNotNil(result.errorMessage)
    }

    func testCancelledUploadIsNotReportedAsSuccessful() async {
        StubSpeechProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await makeClient().transcribe(audioData: Data([1]), apiKey: "test-only-key")
            XCTFail("Cancelled requests must not produce a transcript")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    private func makeClient() -> DoubaoClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSpeechProtocol.self]
        return DoubaoClient(session: URLSession(configuration: configuration))
    }

    private func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class StubSpeechProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
