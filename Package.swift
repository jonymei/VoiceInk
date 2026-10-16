// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInkDoubaoTests",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "DoubaoClient",
            path: "VoiceInk/Infrastructure/Providers/Transcription/Cloud",
            exclude: [
                "Streaming", "AssemblyAIProvider.swift", "CartesiaProvider.swift", "CloudProvider.swift",
                "CloudTranscriptionService.swift", "CustomModelConnectionTester.swift", "DeepgramProvider.swift",
                "DoubaoProvider.swift", "ElevenLabsProvider.swift", "GeminiProvider.swift", "GroqProvider.swift",
                "MistralProvider.swift", "OpenAICompatibleTranscriptionService.swift", "OpenRouterProvider.swift",
                "QwenProvider.swift", "SonioxProvider.swift", "SpeechmaticsProvider.swift", "XAIProvider.swift",
            ],
            sources: ["Doubao", "Qwen"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "EnhancementPolicy",
            path: "VoiceInk/Core/Enhancement",
            exclude: ["AIPrompts.swift", "EnhancementFailureFormatter.swift", "AIEnhancementOutputFilter.swift"],
            sources: ["EnhancementStrategy.swift"]
        ),
        .testTarget(
            name: "DoubaoClientTests",
            dependencies: ["DoubaoClient", "EnhancementPolicy"],
            path: "Tests/DoubaoClientTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
