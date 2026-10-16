import Foundation
import SwiftData

struct QwenProvider: CloudProvider {
    let modelProvider: ModelProvider = .qwen
    let providerKey = "Bailian"
    let includesAutoDetect = true
    let languageCodes: [String]? = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi", "ar", "fr", "de", "es", "pt",
        "ru", "it", "nl", "sv", "da", "fi", "no", "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk",
    ]

    var models: [CloudModel] {
        [CloudModel(name: "qwen-asr-message-smooth", displayName: "Qwen Audio 3.1 ASR",
                    description: "Real-time speech recognition with native text cleanup.",
                    provider: .qwen, isMultilingual: true, supportsStreaming: true, supportedLanguages: supportedLanguages)]
    }

    private var supportedLanguages: [String: String] { LanguageDictionary.forCodes(languageCodes ?? [], includesAutoDetect: true) }

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
                    customVocabulary: [String], timeout: TimeInterval) async throws -> String {
        guard models.contains(where: { $0.name == model }) else { throw CloudTranscriptionError.unsupportedModel(model) }
        return try await QwenASRClient.transcribeWAV(audioData, apiKey: apiKey, configuration: .saved,
                                                   smoothing: model.hasSuffix("-smooth"), language: language,
                                                   vocabulary: customVocabulary, timeout: timeout)
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        QwenStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        let client = QwenASRClient()
        do {
            try await client.connect(apiKey: key, configuration: .saved)
            await client.disconnect()
            return (true, nil)
        } catch {
            await client.disconnect()
            return (false, error.localizedDescription)
        }
    }
}
