import Foundation

enum DoubaoError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case emptyAudio
    case audioTooLarge
    case invalidResponse
    case noSpeech
    case http(Int)
    case service(String, logID: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "Enter a Doubao Speech API key from the new Volcengine console.")
        case .emptyAudio:
            return String(localized: "The audio recording is empty.")
        case .audioTooLarge:
            return String(localized: "Doubao Speech Flash accepts audio files up to 100 MB.")
        case .invalidResponse:
            return String(localized: "Doubao Speech returned an invalid response.")
        case .noSpeech:
            return String(localized: "Doubao Speech did not detect any speech in the recording.")
        case .http(let status):
            return String(format: String(localized: "Doubao Speech request failed (HTTP %lld). Check your API key and service access."), Int64(status))
        case .service(let code, let logID):
            let message = String(format: String(localized: "Doubao Speech request failed (code %@). Check your service permissions, quota, and audio format."), code)
            return logID.map { "\(message) [Log ID: \($0)]" } ?? message
        }
    }
}

struct DoubaoClient: Sendable {
    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let resourceID = "volc.bigasr.auc_turbo"
    static let maximumAudioBytes = 100_000_000

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral, delegate: DoubaoSessionDelegate(), delegateQueue: nil)) {
        self.session = session
    }

    func makeRequest(
        audioData: Data, apiKey: String, customVocabulary: [String] = [], timeout: TimeInterval = 120
    ) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw DoubaoError.missingAPIKey
        }
        guard !audioData.isEmpty else { throw DoubaoError.emptyAudio }
        guard audioData.count <= Self.maximumAudioBytes else { throw DoubaoError.audioTooLarge }

        var options: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
        ]
        var seen = Set<String>()
        let words = customVocabulary.compactMap { word -> [String: String]? in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return ["word": trimmed]
        }.prefix(5000)
        if !words.isEmpty {
            let contextData = try JSONSerialization.data(withJSONObject: ["hotwords": Array(words)])
            options["corpus"] = ["context": String(decoding: contextData, as: UTF8.self)]
        }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(Self.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "voiceink"],
            "audio": ["data": audioData.base64EncodedString()],
            "request": options,
        ])
        return request
    }

    func transcribe(
        audioData: Data, apiKey: String, customVocabulary: [String] = [], timeout: TimeInterval = 120
    ) async throws -> String {
        let request = try makeRequest(
            audioData: audioData, apiKey: apiKey, customVocabulary: customVocabulary, timeout: timeout
        )
        let (data, response) = try await session.data(for: request)
        return try parseResponse(data: data, response: response)
    }

    func parseResponse(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw DoubaoError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DoubaoError.http(http.statusCode) }
        guard let code = http.value(forHTTPHeaderField: "X-Api-Status-Code") else {
            throw DoubaoError.invalidResponse
        }
        if code == "20000003" { throw DoubaoError.noSpeech }
        guard code == "20000000" else {
            throw DoubaoError.service(code, logID: http.value(forHTTPHeaderField: "X-Tt-Logid"))
        }
        guard let result = try? JSONDecoder().decode(RecognitionResponse.self, from: data) else {
            throw DoubaoError.invalidResponse
        }
        let text = result.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DoubaoError.noSpeech }
        return text
    }

    func verifyAPIKey(_ apiKey: String) async -> (isValid: Bool, errorMessage: String?) {
        do {
            _ = try await transcribe(audioData: Self.verificationAudio, apiKey: apiKey, timeout: 30)
            return (true, nil)
        } catch DoubaoError.noSpeech {
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static var verificationAudio: Data {
        let sampleBytes: UInt32 = 16_000 * 2
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append(sampleBytes + 36)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(Data("data".utf8))
        append(sampleBytes)
        wav.append(Data(count: Int(sampleBytes)))
        return wav
    }

    private struct RecognitionResponse: Decodable {
        let result: Result

        struct Result: Decodable {
            let text: String
        }
    }
}

final class DoubaoSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward the speech API key or audio to a redirect target.
        completionHandler(nil)
    }
}
