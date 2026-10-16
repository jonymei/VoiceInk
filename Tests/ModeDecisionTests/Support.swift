// Unrelated app services are stand-ins; mode storage values, drafts and runtime resolution are real sources.
enum ConfigurationMode {
    case add, edit(ModeConfig)
}

final class ModeManager {
    static let shared = ModeManager()
    var configurations: [ModeConfig] = []
    var currentEffectiveConfiguration: ModeConfig? { configurations.first }
    func getConfiguration(with id: UUID) -> ModeConfig? { configurations.first { $0.id == id } }
}

enum AIProvider: String {
    case qwen, voiceInkRefine, localCLI
    var defaultModel: String { "test-model" }
    var supportsCustomModelID: Bool { true }
}

struct CustomPrompt { let id: UUID }
final class AIService {
    var connectedProviders: [AIProvider] = [.qwen]
    func availableModels(for provider: AIProvider) -> [String] { [provider.defaultModel] }
}
final class AIEnhancementService { var allPrompts: [CustomPrompt] = [] }

enum TestTranscriptionProvider { case whisper }
protocol TranscriptionModel {
    var provider: TestTranscriptionProvider { get }
    var selectionKey: String { get }
}
final class TranscriptionModelManager {
    var allAvailableModels: [any TranscriptionModel] = []
    var usableModels: [any TranscriptionModel] = []
}
enum TranscriptionModelRegistry {
    static func model(forSelectionKey key: String, in models: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        models.first { $0.selectionKey == key }
    }
}
enum TranscriptionLanguageSupport {
    static func validLanguageOrFallback(_ language: String?, for model: any TranscriptionModel, realtimeEnabled: Bool) -> String {
        language ?? "en"
    }
}
enum TranscriptionRealtimeSupport {
    static func isEnabled(for model: any TranscriptionModel, modeValue: Bool) -> Bool { modeValue }
}
enum WhisperPrompt {
    static func resolvedPrompt(for language: String) -> String? { nil }
}
struct TranscriptionRequestContext {
    let language: String
    let prompt: String?
}
struct ModeFormWarmupSnapshot {
    var connectedAIProviders: [AIProvider] = []
    var usableTranscriptionModels: [any TranscriptionModel] = []
    func availableModels(for provider: AIProvider) -> [String] { [] }
    func selectedModel(for provider: AIProvider) -> String { provider.defaultModel }
    func hasUsableTranscriptionModel(named name: String) -> Bool { false }
}
