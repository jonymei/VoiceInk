import Foundation
import SwiftData

struct DoubaoProvider: CloudProvider {
    let modelProvider: ModelProvider = .doubao
    let providerKey = "Doubao"
    let languageCodes: [String]? = []
    let includesAutoDetect = true

    var models: [CloudModel] {
        [
            CloudModel(name: "doubao-asr-sentence", displayName: String(localized: "Doubao Sentence Recognition"),
                       description: "Returns complete recognition after speech ends, prioritizing accuracy.",
                       provider: .doubao, isMultilingual: true, supportsStreaming: true,
                       supportedLanguages: LanguageDictionary.forCodes([], includesAutoDetect: true)),
            CloudModel(name: "doubao-asr-streaming-v2", displayName: String(localized: "Doubao Realtime Recognition"),
                       description: "Low-latency incremental recognition while speaking.",
                       provider: .doubao, isMultilingual: true, supportsStreaming: true,
                       supportedLanguages: LanguageDictionary.forCodes([], includesAutoDetect: true)),
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        guard models.contains(where: { $0.name == model }) else {
            throw CloudTranscriptionError.unsupportedModel(model)
        }
        return try await DoubaoStreamingClient.transcribeWAV(
            audioData, apiKey: apiKey, customVocabulary: customVocabulary,
            resourceID: Self.resourceID(for: model), timeout: timeout, smoothing: true,
            sentence: model == "doubao-asr-sentence"
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        DoubaoStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        let client = DoubaoStreamingClient()
        do {
            try await client.connect(apiKey: key)
            await client.disconnect()
            return (true, nil)
        } catch {
            await client.disconnect()
            return (false, error.localizedDescription)
        }
    }

    static func resourceID(for model: String) -> String {
        DoubaoStreamingClient.resourceID
    }
}
