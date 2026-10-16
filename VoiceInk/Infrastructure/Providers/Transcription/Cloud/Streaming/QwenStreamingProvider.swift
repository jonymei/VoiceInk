import Foundation
import SwiftData

final class QwenStreamingProvider: StreamingTranscriptionProvider {
    private let client = QwenASRClient()
    private let modelContext: ModelContext
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private var forwardingTask: Task<Void, Never>?

    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    var finalizationEvents: AsyncStream<String>? { client.finalizationEvents }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        (transcriptionEvents, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
    }

    deinit {
        forwardingTask?.cancel(); continuation.finish()
        let client = client
        Task { await client.disconnect() }
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Bailian"), !key.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        let words = (try? modelContext.fetch(descriptor))?.map(\.word) ?? []
        try await client.connect(apiKey: key, configuration: .saved, smoothing: model.name.hasSuffix("-smooth"),
                                 language: language, vocabulary: words)
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

    func sendAudioChunk(_ data: Data) async throws { try await client.sendAudioChunk(data) }
    func commit() async throws { try await client.commit() }
    func disconnect() async {
        forwardingTask?.cancel(); forwardingTask = nil
        await client.disconnect(); continuation.finish()
    }
}
