import Foundation

enum BailianRegion: String, CaseIterable, Sendable {
    case beijing = "cn-beijing"
    case singapore = "ap-southeast-1"
}

struct BailianConfiguration: Sendable {
    let workspaceID: String
    let region: BailianRegion

    static var saved: Self {
        Self(
            workspaceID: UserDefaults.standard.string(forKey: "BailianWorkspaceID") ?? "",
            region: BailianRegion(rawValue: UserDefaults.standard.string(forKey: "BailianRegion") ?? "") ?? .beijing
        )
    }

    func endpoint(path: String, websocket: Bool = false) throws -> URL {
        let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty, workspace.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }) else { throw QwenASRError.configuration }
        return URL(string: "\(websocket ? "wss" : "https")://\(workspace).\(region.rawValue).maas.aliyuncs.com\(path)")!
    }
}

enum QwenASRError: Error, LocalizedError, Equatable {
    case configuration, missingAPIKey, invalidResponse, notConnected, timeout, network, invalidAudio
    case http(Int)
    case service

    var errorDescription: String? {
        switch self {
        case .configuration: return String(localized: "Configure the Bailian workspace ID and matching region first.")
        case .missingAPIKey: return String(localized: "Configure a Bailian API key first.")
        case .invalidResponse: return String(localized: "Bailian returned an invalid or incomplete recognition response.")
        case .notConnected: return String(localized: "Qwen ASR is not connected.")
        case .timeout: return String(localized: "Qwen ASR timed out waiting for confirmation.")
        case .network: return String(localized: "Could not connect to Qwen ASR. Check your network and service access.")
        case .invalidAudio: return String(localized: "Qwen ASR requires 16-bit mono PCM audio at 16 kHz.")
        case .http(let status): return String(format: String(localized: "Bailian request failed (HTTP %lld). Check the API key, workspace, region and quota."), Int64(status))
        case .service: return String(localized: "Bailian recognition failed. Check model access, workspace and quota.")
        }
    }
}

protocol QwenASRSocket: Sendable {
    func sendText(_ text: String) async throws
    func sendAudio(_ audio: Data) async throws
    func receive() async throws -> Data
    func close() async
}

enum QwenASREvent: Sendable {
    case partial(String)
    case final(String)
    case error(QwenASRError)
}

enum QwenASRProtocol {
    static let model = "qwen-audio-3.1-asr-flash-message"

    static func start(taskID: String, smoothing: Bool, language: String?, vocabulary: [String]) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm", "sample_rate": 16000, "intermediate_result_enabled": true,
            "disfluency_removal_enabled": smoothing, "vad_model": "near_meeting_16k",
            "heartbeat": true,
        ]
        if let language, !language.isEmpty, language != "auto" { parameters["language_hints"] = [language] }
        var words: [String: Int] = [:]
        var seen = Set<String>()
        for word in vocabulary {
            let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            words[word] = 3
            if words.count == 2000 { break }
        }
        if !words.isEmpty { parameters["vocabulary"] = words }
        return try json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                        "model": model, "parameters": parameters, "input": [:]],
        ])
    }

    static func finish(taskID: String) throws -> String {
        try json(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
                  "payload": ["input": [:]]])
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    struct Response: Decodable {
        struct Header: Decodable { let event: String; let task_id: String }
        struct Payload: Decodable {
            struct Output: Decodable {
                struct Sentence: Decodable {
                    let sentence_id: Int
                    let text: String?
                    let sentence_end: Bool?
                    let heartbeat: Bool?
                }
                let sentence: Sentence?
            }
            let output: Output?
        }
        let header: Header
        let payload: Payload?

        static func parse(_ data: Data, taskID: String) throws -> Self {
            guard data.count <= 4_000_000, let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.header.task_id == taskID else { throw QwenASRError.invalidResponse }
            if value.header.event == "task-failed" { throw QwenASRError.service }
            return value
        }
    }
}

actor QwenASRClient {
    nonisolated let events: AsyncStream<QwenASREvent>
    nonisolated let finalizationEvents: AsyncStream<String>
    private let continuation: AsyncStream<QwenASREvent>.Continuation
    private let finalContinuation: AsyncStream<String>.Continuation
    private let socketFactory: @Sendable (URLRequest) -> any QwenASRSocket
    private var socket: (any QwenASRSocket)?
    private var receiver: Task<Void, Never>?
    private let taskID = UUID().uuidString
    private var sentences: [Int: String] = [:]
    private var completed = Set<Int>()
    private var finishing = false
    private var closed = false
    private var terminalError: QwenASRError?

    init(socketFactory: @escaping @Sendable (URLRequest) -> any QwenASRSocket = { QwenURLSessionSocket(request: $0) }) {
        (events, continuation) = AsyncStream.makeStream(of: QwenASREvent.self)
        (finalizationEvents, finalContinuation) = AsyncStream.makeStream(of: String.self)
        self.socketFactory = socketFactory
    }

    deinit { receiver?.cancel(); continuation.finish(); finalContinuation.finish() }

    static func request(apiKey: String, configuration: BailianConfiguration) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw QwenASRError.missingAPIKey }
        var request = URLRequest(url: try configuration.endpoint(path: "/api-ws/v1/inference", websocket: true),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    func connect(apiKey: String, configuration: BailianConfiguration, smoothing: Bool = false,
                 language: String? = nil, vocabulary: [String] = []) async throws {
        guard socket == nil, !closed else { throw QwenASRError.notConnected }
        let socket = socketFactory(try Self.request(apiKey: apiKey, configuration: configuration))
        self.socket = socket
        do {
            try await socket.sendText(QwenASRProtocol.start(taskID: taskID, smoothing: smoothing, language: language, vocabulary: vocabulary))
            let taskID = taskID
            let response = try await withThrowingTaskGroup(of: QwenASRProtocol.Response.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try QwenASRProtocol.Response.parse(await socket.receive(), taskID: taskID)
                    } onCancel: { Task { await socket.close() } }
                }
                group.addTask { try await Task.sleep(for: .seconds(15)); throw QwenASRError.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard !closed else { throw CancellationError() }
            guard response.header.event == "task-started" else { throw QwenASRError.invalidResponse }
            receiver = Task { [weak self] in await self?.receiveLoop(socket) }
        } catch {
            await disconnect()
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw (error as? QwenASRError) ?? .network
        }
    }

    func sendAudioChunk(_ audio: Data) async throws {
        if let terminalError { throw terminalError }
        guard let socket, !finishing, !closed else { throw QwenASRError.notConnected }
        guard audio.count.isMultiple(of: 2) else { throw QwenASRError.invalidAudio }
        do {
            for start in stride(from: 0, to: audio.count, by: 6400) {
                try await socket.sendAudio(audio.subdata(in: start..<min(start + 6400, audio.count)))
            }
        } catch { await fail(error); throw terminalError ?? .network }
    }

    func commit() async throws {
        if let terminalError { throw terminalError }
        guard let socket, !finishing, !closed else { throw QwenASRError.notConnected }
        finishing = true
        do { try await socket.sendText(QwenASRProtocol.finish(taskID: taskID)) }
        catch { await fail(error); throw terminalError ?? .network }
    }

    func disconnect() async {
        closed = true
        receiver?.cancel(); receiver = nil
        let previous = socket; socket = nil
        await previous?.close()
        continuation.finish(); finalContinuation.finish()
    }

    static func transcribeWAV(_ wav: Data, apiKey: String, configuration: BailianConfiguration,
                              smoothing: Bool, language: String?, vocabulary: [String], timeout: TimeInterval) async throws -> String {
        let client = QwenASRClient()
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await client.transcribeFile(wav, apiKey: apiKey, configuration: configuration,
                                                    smoothing: smoothing, language: language, vocabulary: vocabulary)
                }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); throw QwenASRError.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await client.disconnect(); return text
        } catch { await client.disconnect(); throw error }
    }

    func transcribeFile(_ wav: Data, apiKey: String, configuration: BailianConfiguration,
                        smoothing: Bool, language: String?, vocabulary: [String]) async throws -> String {
        let audio = try DoubaoStreamingProtocol.pcmAudio(fromWAV: wav)
        try await connect(apiKey: apiKey, configuration: configuration, smoothing: smoothing, language: language, vocabulary: vocabulary)
        for start in stride(from: 0, to: audio.count, by: 6400) {
            try Task.checkCancellation()
            try await sendAudioChunk(audio.subdata(in: start..<min(start + 6400, audio.count)))
            try await Task.sleep(for: .milliseconds(200))
        }
        try await commit()
        for await text in finalizationEvents { return text }
        try Task.checkCancellation()
        throw terminalError ?? .invalidResponse
    }

    private func receiveLoop(_ socket: any QwenASRSocket) async {
        do {
            while !Task.isCancelled, !closed {
                let response = try QwenASRProtocol.Response.parse(await socket.receive(), taskID: taskID)
                guard !closed, !Task.isCancelled else { return }
                switch response.header.event {
                case "result-generated":
                    guard let sentence = response.payload?.output?.sentence else { throw QwenASRError.invalidResponse }
                    if sentence.heartbeat == true { continue }
                    guard sentence.sentence_id > 0, let text = sentence.text else { throw QwenASRError.invalidResponse }
                    // A final sentence may arrive again; replace by ID, never append duplicate text.
                    if !completed.contains(sentence.sentence_id) || sentence.sentence_end == true {
                        sentences[sentence.sentence_id] = text
                    }
                    if sentence.sentence_end == true { completed.insert(sentence.sentence_id) }
                    continuation.yield(.partial(transcript))
                case "task-finished":
                    guard finishing, Set(sentences.keys).isSubset(of: completed) else { throw QwenASRError.invalidResponse }
                    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.final(text)); finalContinuation.yield(text)
                    await disconnect(); return
                default: throw QwenASRError.invalidResponse
                }
            }
        } catch {
            guard !closed, !Task.isCancelled else { return }
            await fail(error)
        }
    }

    private var transcript: String {
        sentences.keys.sorted().compactMap { sentences[$0] }.reduce("") { result, sentence in
            guard let last = result.last, let first = sentence.first else { return result + sentence }
            let separator = last.isASCII && first.isASCII && !last.isWhitespace && first.isLetter ? " " : ""
            return result + separator + sentence
        }
    }

    private func fail(_ error: Error) async {
        let error = (error as? QwenASRError) ?? .network
        terminalError = error; continuation.yield(.error(error))
        await disconnect()
    }
}

final class QwenURLSessionSocket: QwenASRSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral, delegate: DoubaoSessionDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request); task.maximumMessageSize = 4_000_000; task.resume()
    }

    func sendText(_ text: String) async throws { try await send(.string(text)) }
    func sendAudio(_ audio: Data) async throws { try await send(.data(audio)) }
    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        do { try await task.send(message) } catch { throw mapped(error) }
    }
    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: throw QwenASRError.invalidResponse
            }
        } catch { throw mapped(error) }
    }
    private func mapped(_ error: Error) -> QwenASRError {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 { return .http(response.statusCode) }
        return (error as? QwenASRError) ?? .network
    }
    func close() async { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    deinit { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
