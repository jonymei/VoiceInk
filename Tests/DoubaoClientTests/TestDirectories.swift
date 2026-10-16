import Foundation

enum TestDirectories {
    static func unique(_ component: String) -> URL {
        let root = ProcessInfo.processInfo.environment["VOICEINK_TEST_TMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInkTests.noindex")
        return root.appendingPathComponent(component).appendingPathComponent(UUID().uuidString)
    }
}
