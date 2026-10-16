import Foundation

protocol DoubaoWebSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

enum DoubaoStreamEvent: Sendable {
    case partial(String)
    case final(String)
    case error(DoubaoStreamingError)
}

actor DoubaoStreamingClient {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let resourceID = "volc.seedasr.sauc.duration"
    static let chunkBytes = 6400

    nonisolated let events: AsyncStream<DoubaoStreamEvent>
    nonisolated let finalizationEvents: AsyncStream<String>
    private let continuation: AsyncStream<DoubaoStreamEvent>.Continuation
    private let finalContinuation: AsyncStream<String>.Continuation
    private let socketFactory: @Sendable (URLRequest) -> any DoubaoWebSocket
    private var socket: (any DoubaoWebSocket)?
    private var receiver: Task<Void, Never>?
    private var pendingAudio = Data()
    private var latestText = ""
    private var finishing = false
    private var generation = 0
    private var terminalError: DoubaoStreamingError?

    init(socketFactory: @escaping @Sendable (URLRequest) -> any DoubaoWebSocket = { DoubaoURLSessionSocket(request: $0) }) {
        let (events, continuation) = AsyncStream.makeStream(of: DoubaoStreamEvent.self)
        self.events = events
        self.continuation = continuation
        let (finals, finalContinuation) = AsyncStream.makeStream(of: String.self)
        finalizationEvents = finals
        self.finalContinuation = finalContinuation
        self.socketFactory = socketFactory
    }

    deinit {
        receiver?.cancel()
        continuation.finish()
        finalContinuation.finish()
    }

    static func makeRequest(apiKey: String, resourceID: String = DoubaoStreamingClient.resourceID, sentence: Bool = false) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw DoubaoError.missingAPIKey
        }
        var request = URLRequest(url: sentence ? URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")! : endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        return request
    }

    func connect(apiKey: String, customVocabulary: [String] = [], resourceID: String = DoubaoStreamingClient.resourceID, smoothing: Bool = false, sentence: Bool = false) async throws {
        guard socket == nil, !finishing else { throw DoubaoStreamingError.notConnected }
        let socket = socketFactory(try Self.makeRequest(apiKey: apiKey, resourceID: resourceID, sentence: sentence))
        self.socket = socket
        let currentGeneration = generation
        do {
            try await socket.send(DoubaoStreamingProtocol.configuration(customVocabulary: customVocabulary, smoothing: smoothing))
            let response = try await withThrowingTaskGroup(of: DoubaoStreamingProtocol.Response.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try DoubaoStreamingProtocol.parse(await socket.receive())
                    } onCancel: {
                        Task { await socket.close() }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw DoubaoStreamingError.connectionFailed
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard generation == currentGeneration else { throw CancellationError() }
            try handle(response)
            receiver = Task { [weak self] in
                await self?.receiveLoop(socket: socket, generation: currentGeneration)
            }
        } catch {
            await socket.close()
            self.socket = nil
            if let error = error as? DoubaoStreamingError { throw error }
            if error is CancellationError { throw error }
            throw DoubaoStreamingError.connectionFailed
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        if let terminalError { throw terminalError }
        guard let socket, !finishing else { throw DoubaoStreamingError.notConnected }
        guard data.count.isMultiple(of: 2) else { throw DoubaoStreamingError.invalidAudio }
        pendingAudio.append(data)
        // Retain the last chunk so the terminal packet contains real captured audio.
        while pendingAudio.count > Self.chunkBytes {
            let chunk = Data(pendingAudio.prefix(Self.chunkBytes))
            pendingAudio.removeFirst(Self.chunkBytes)
            try await send(DoubaoStreamingProtocol.audio(chunk), to: socket)
        }
    }

    func commit() async throws {
        if let terminalError { throw terminalError }
        guard let socket, !finishing else { throw DoubaoStreamingError.notConnected }
        finishing = true
        let finalAudio = pendingAudio.isEmpty ? Data([0, 0]) : pendingAudio
        pendingAudio.removeAll()
        try await send(DoubaoStreamingProtocol.audio(finalAudio, isFinal: true), to: socket)
    }

    func disconnect() async {
        generation += 1
        receiver?.cancel()
        receiver = nil
        let previousSocket = socket
        socket = nil
        finishing = true
        pendingAudio.removeAll()
        await previousSocket?.close()
        continuation.finish()
        finalContinuation.finish()
    }

    static func transcribeWAV(
        _ wav: Data, apiKey: String, customVocabulary: [String] = [],
        resourceID: String = DoubaoStreamingClient.resourceID, timeout: TimeInterval = 120, smoothing: Bool = false, sentence: Bool = false
    ) async throws -> String {
        let client = DoubaoStreamingClient()
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await client.transcribeFile(wav, apiKey: apiKey, customVocabulary: customVocabulary, resourceID: resourceID, smoothing: smoothing, sentence: sentence)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw DoubaoStreamingError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await client.disconnect()
            return text
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func transcribeFile(
        _ wav: Data, apiKey: String, customVocabulary: [String] = [],
        resourceID: String = DoubaoStreamingClient.resourceID, smoothing: Bool = false, sentence: Bool = false
    ) async throws -> String {
        let audio = try DoubaoStreamingProtocol.pcmAudio(fromWAV: wav)
        try await connect(apiKey: apiKey, customVocabulary: customVocabulary, resourceID: resourceID, smoothing: smoothing, sentence: sentence)
        for start in stride(from: 0, to: audio.count, by: Self.chunkBytes) {
            try Task.checkCancellation()
            try await sendAudioChunk(audio.subdata(in: start..<min(start + Self.chunkBytes, audio.count)))
            try await Task.sleep(for: .milliseconds(200))
        }
        try await commit()
        for await text in finalizationEvents {
            guard !text.isEmpty else { throw DoubaoError.noSpeech }
            return text
        }
        if let terminalError { throw terminalError }
        try Task.checkCancellation()
        throw DoubaoStreamingError.connectionFailed
    }

    private func receiveLoop(socket: any DoubaoWebSocket, generation: Int) async {
        do {
            while !Task.isCancelled, self.generation == generation {
                let response = try DoubaoStreamingProtocol.parse(await socket.receive())
                guard self.generation == generation, !Task.isCancelled else { return }
                try handle(response)
                if response.isFinal { return }
            }
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            let failure = (error as? DoubaoStreamingError) ?? .connectionFailed
            terminalError = failure
            continuation.yield(.error(failure))
            continuation.finish()
            finalContinuation.finish()
            await socket.close()
        }
    }

    private func send(_ data: Data, to socket: any DoubaoWebSocket) async throws {
        do {
            try await socket.send(data)
        } catch {
            let failure = (error as? DoubaoStreamingError) ?? .connectionFailed
            terminalError = failure
            continuation.yield(.error(failure))
            continuation.finish()
            finalContinuation.finish()
            await socket.close()
            throw failure
        }
    }

    private func handle(_ response: DoubaoStreamingProtocol.Response) throws {
        guard !response.isFinal || finishing else { throw DoubaoStreamingError.invalidPacket }
        if let text = response.text { latestText = text }
        if response.isFinal {
            let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.final(text))
            finalContinuation.yield(text)
            continuation.finish()
            finalContinuation.finish()
        } else if let text = response.text {
            continuation.yield(.partial(text))
        }
    }
}

final class DoubaoURLSessionSocket: DoubaoWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral, delegate: DoubaoSessionDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4_000_064
        task.resume()
    }

    func send(_ data: Data) async throws {
        do {
            try await task.send(.data(data))
        } catch {
            throw mappedError(error)
        }
    }

    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            default: throw DoubaoStreamingError.invalidPacket
            }
        } catch {
            if let error = error as? DoubaoStreamingError { throw error }
            throw mappedError(error)
        }
    }

    private func mappedError(_ error: Error) -> DoubaoStreamingError {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return .http(response.statusCode)
        }
        return .transport((error as NSError).code)
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
