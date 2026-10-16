import Foundation
import SwiftData

final class DoubaoStreamingProvider: StreamingTranscriptionProvider {
    private let client = DoubaoStreamingClient()
    private let modelContext: ModelContext
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private var forwardingTask: Task<Void, Never>?

    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var finalizationEvents: AsyncStream<String>? { client.finalizationEvents }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        let (events, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = events
        self.continuation = continuation
    }

    deinit {
        forwardingTask?.cancel()
        continuation.finish()
        let client = client
        Task { await client.disconnect() }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Doubao"), !key.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        let vocabulary = (try? modelContext.fetch(descriptor))?.map(\.word) ?? []
        try await client.connect(
            apiKey: key, customVocabulary: vocabulary,
            resourceID: DoubaoProvider.resourceID(for: model.name), smoothing: true, sentence: model.name == "doubao-asr-sentence"
        )
        continuation.yield(.sessionStarted)
        let continuation = continuation
        let events = client.events
        forwardingTask = Task {
            for await event in events {
                switch event {
                case .partial(let text): continuation.yield(.partial(text: text))
                case .final(let text): continuation.yield(.committed(text: text))
                case .error(let error): continuation.yield(.error(error))
                }
            }
            continuation.finish()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        try await client.sendAudioChunk(data)
    }

    func commit() async throws {
        try await client.commit()
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await client.disconnect()
        continuation.finish()
    }
}
