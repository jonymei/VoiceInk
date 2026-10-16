import Foundation
import XCTest
@testable import DoubaoClient

final class DoubaoStreamingTests: XCTestCase {
    func testHandshakeUsesRealtimeModelTwoAndSpeechKey() throws {
        let request = try DoubaoStreamingClient.makeRequest(apiKey: "test-only-key")
        XCTAssertEqual(request.url?.absoluteString, "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "test-only-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.sauc.duration")
        XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "X-Api-Request-Id")!))
        let legacy = try DoubaoStreamingClient.makeRequest(apiKey: "test-only-key", resourceID: "volc.bigasr.sauc.duration")
        XCTAssertEqual(legacy.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.sauc.duration")
    }

    func testConfigurationMatchesBinaryProtocolAndPCMContract() throws {
        let packet = try DoubaoStreamingProtocol.configuration(customVocabulary: [" VoiceInk ", "voiceink", "Rime"])
        XCTAssertEqual(Array(packet.prefix(4)), [0x11, 0x10, 0x10, 0])
        let length = packet[4..<8].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(length, packet.count - 8)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.dropFirst(8)) as? [String: Any])
        let audio = try XCTUnwrap(body["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["rate"] as? Int, 16000)
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)
        let options = try XCTUnwrap(body["request"] as? [String: Any])
        XCTAssertEqual(options["enable_nonstream"] as? Bool, true)
        let context = try XCTUnwrap((options["corpus"] as? [String: String])?["context"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: [[String: String]]])
        XCTAssertEqual(decoded["hotwords"], [["word": "VoiceInk"], ["word": "Rime"]])
    }

    func testAudioPacketAndFinalFlag() {
        XCTAssertEqual(Array(DoubaoStreamingProtocol.audio(Data([1, 2]))), [0x11, 0x20, 0, 0, 0, 0, 0, 2, 1, 2])
        XCTAssertEqual(Array(DoubaoStreamingProtocol.audio(Data([3, 4]), isFinal: true)), [0x11, 0x22, 0, 0, 0, 0, 0, 2, 3, 4])
    }

    func testGzipResponseIsDecodedAndCorruptCompressionIsRejected() throws {
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/6tWKkotLs0pUbKqVipJrQDSSsn5uQVAweLUFKXaWgAuXFisIAAAAA==")!
        var packet = Data([0x11, 0x92, 0x11, 0])
        var size = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(compressed)
        XCTAssertEqual(try DoubaoStreamingProtocol.parse(packet), .init(text: "compressed", isFinal: true))
        packet[8] = 0
        XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(packet))
    }

    func testAcknowledgementAndArrayResult() throws {
        XCTAssertEqual(try DoubaoStreamingProtocol.parse(Self.response(text: nil)), .init(text: nil, isFinal: false))
        let payload = Data(#"{"result":[{"text":"One."},{"text":"Two."}]}"#.utf8)
        var packet = Data([0x11, 0x92, 0x10, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        XCTAssertEqual(try DoubaoStreamingProtocol.parse(packet), .init(text: "One.Two.", isFinal: true))
    }

    func testCumulativePartialAndNegativeSequenceTerminalPacket() throws {
        let partial = try DoubaoStreamingProtocol.parse(Self.response(text: "A"))
        XCTAssertEqual(partial, .init(text: "A", isFinal: false))
        let final = try DoubaoStreamingProtocol.parse(Self.response(text: "A complete sentence.", final: true))
        XCTAssertEqual(final, .init(text: "A complete sentence.", isFinal: true))
    }

    func testMetadataOnlyAcknowledgementAndInvalidText() throws {
        XCTAssertEqual(try DoubaoStreamingProtocol.parse(Self.acknowledgement), .init(text: nil, isFinal: false))
        let payload = Data(#"{"result":{"text":123}}"#.utf8)
        var invalid = Data([0x11, 0x90, 0x10, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { invalid.append(contentsOf: $0) }
        invalid.append(payload)
        XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(invalid))
    }

    func testServerErrorIsNeverDecodedAsTranscript() {
        var packet = Data([0x11, 0xf0, 0x10, 0])
        var code = UInt32(45000001).bigEndian
        withUnsafeBytes(of: &code) { packet.append(contentsOf: $0) }
        packet.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(packet)) {
            XCTAssertEqual($0 as? DoubaoStreamingError, .server(45000001))
        }
    }

    func testTruncatedAndMalformedPacketsAreRejected() {
        let valid = Self.response(text: "test")
        for size in 0..<valid.count {
            XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(Data(valid.prefix(size))))
        }
        var invalidVersion = valid
        invalidVersion[0] = 0x21
        XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(invalidVersion))
        var unsupportedCompression = valid
        unsupportedCompression[2] = 0x12
        XCTAssertThrowsError(try DoubaoStreamingProtocol.parse(unsupportedCompression))
    }

    func testWAVDecoderReadsPCMAndRejectsWrongRate() throws {
        let wav = DoubaoClient.verificationAudio
        XCTAssertEqual(try DoubaoStreamingProtocol.pcmAudio(fromWAV: wav), Data(count: 32000))
        var wrongRate = wav
        wrongRate[24] = 0
        XCTAssertThrowsError(try DoubaoStreamingProtocol.pcmAudio(fromWAV: wrongRate))
        XCTAssertThrowsError(try DoubaoStreamingProtocol.pcmAudio(fromWAV: Data(wav.prefix(40))))
        XCTAssertThrowsError(try DoubaoStreamingProtocol.pcmAudio(fromWAV: Data("not WAV".utf8)))
    }

    func testStreamingRoundTripPreservesAudioAndFinalizesOnlyOnce() async throws {
        let socket = ScriptedSpeechSocket()
        let client = DoubaoStreamingClient(socketFactory: { _ in socket })
        try await client.connect(apiKey: "test-only-key")
        let audio = Data((0..<16000).map { UInt8($0 % 256) })
        try await client.sendAudioChunk(audio.prefix(1000))
        try await client.sendAudioChunk(audio.dropFirst(1000))
        try await client.commit()
        var finals = client.finalizationEvents.makeAsyncIterator()
        let finalText = await finals.next()
        XCTAssertEqual(finalText, "Final complete transcript.")
        let next = await finals.next()
        XCTAssertNil(next)
        let sent = await socket.sent
        XCTAssertEqual(sent.first?[1], 0x10)
        let packets = sent.filter { $0[1] >> 4 == 2 }
        XCTAssertEqual(packets.last?[1], 0x22)
        XCTAssertEqual(packets.dropLast().filter { $0[1] == 0x22 }.count, 0)
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1.dropFirst(8)) }, audio)
        XCTAssertTrue(packets.dropLast().allSatisfy { $0.count == 6408 })
        await client.disconnect()
    }

    func testFileImportUsesSameRealtimeAPI() async throws {
        let socket = ScriptedSpeechSocket()
        let client = DoubaoStreamingClient(socketFactory: { _ in socket })
        let text = try await client.transcribeFile(DoubaoClient.verificationAudio, apiKey: "test-only-key")
        XCTAssertEqual(text, "Final complete transcript.")
        await client.disconnect()
    }

    func testCommitAndAudioAreRejectedAfterDisconnect() async {
        let socket = ScriptedSpeechSocket()
        let client = DoubaoStreamingClient(socketFactory: { _ in socket })
        await client.disconnect()
        do {
            try await client.commit()
            XCTFail("Disconnected client must reject commit")
        } catch {
            XCTAssertEqual(error as? DoubaoStreamingError, .notConnected)
        }
        do {
            try await client.sendAudioChunk(Data([1, 2]))
            XCTFail("Disconnected client must reject audio")
        } catch {
            XCTAssertEqual(error as? DoubaoStreamingError, .notConnected)
        }
    }

    func testOddPCMByteCountIsRejected() async throws {
        let socket = ScriptedSpeechSocket()
        let client = DoubaoStreamingClient(socketFactory: { _ in socket })
        try await client.connect(apiKey: "test-only-key")
        do {
            try await client.sendAudioChunk(Data([1]))
            XCTFail("Odd PCM length must fail")
        } catch {
            XCTAssertEqual(error as? DoubaoStreamingError, .invalidAudio)
        }
        await client.disconnect()
    }

    func testPrematureTerminalPacketCannotFinalizeUnsubmittedAudio() async {
        let socket = ScriptedSpeechSocket(acknowledgement: Self.response(text: "Premature result", final: true))
        let client = DoubaoStreamingClient(socketFactory: { _ in socket })
        do {
            try await client.connect(apiKey: "test-only-key")
            XCTFail("A terminal packet before commit must not be accepted")
        } catch {
            XCTAssertEqual(error as? DoubaoStreamingError, .invalidPacket)
        }
        await client.disconnect()
    }

    static var acknowledgement: Data {
        let payload = Data(#"{"result":{"additions":{"log_id":"test-log"}}}"#.utf8)
        var packet = Data([0x11, 0x90, 0x10, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    static func response(text: String?, final: Bool = false) -> Data {
        let body: [String: Any] = text.map { ["result": ["text": $0]] } ?? ["audio_info": ["duration": 0]]
        let payload = try! JSONSerialization.data(withJSONObject: body)
        var packet = Data([0x11, final ? 0x93 : 0x91, 0x10, 0])
        var sequence = Int32(final ? -3 : 1).bigEndian
        withUnsafeBytes(of: &sequence) { packet.append(contentsOf: $0) }
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }
}

private actor ScriptedSpeechSocket: DoubaoWebSocket {
    private var queue: [Data]
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var sent: [Data] = []

    init(acknowledgement: Data = DoubaoStreamingTests.acknowledgement) {
        queue = [acknowledgement]
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw URLError(.cancelled) }
        sent.append(data)
        if data[1] == 0x20 { deliver(DoubaoStreamingTests.response(text: "Partial transcript")) }
        if data[1] == 0x22 { deliver(DoubaoStreamingTests.response(text: "Final complete transcript.", final: true)) }
    }

    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() async {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }

    private func deliver(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            queue.append(data)
        }
    }
}
