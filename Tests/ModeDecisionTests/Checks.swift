@main
@MainActor
struct ModeDecisionChecks {
    struct Failure: Error { let message: String }
    static var count = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    static func check(_ name: String, _ body: () throws -> Void) throws {
        try body()
        count += 1
        print("PASS: \(name)")
    }

    static func legacyThreshold(_ value: Double) {
        UserDefaults.standard.setVolatileDomain(
            [DecisionSettings.thresholdKey: value], forName: UserDefaults.argumentDomain)
    }

    static func saved(_ threshold: Double) -> ModeConfig {
        var draft = ModeConfigDraft(mode: .add, modeManager: ModeManager())
        draft.name = "mode-\(threshold)"
        draft.isAIEnhancementEnabled = true
        draft.enhancementStrategy = .automatic
        draft.decisionThreshold = threshold
        return draft.makeConfig(mode: .add)
    }

    static func runtime(_ mode: ModeConfig) -> EnhancementRuntimeConfiguration {
        ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: mode, enhancementService: AIEnhancementService(), aiService: AIService())
    }

    static func main() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        legacyThreshold(0.55)
        let original = ModeConfig(name: "old", isAIEnhancementEnabled: true)
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "decisionThreshold")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        try check("legacy mode inherits the previous global threshold") {
            let migrated = try decoder.decode(ModeConfig.self, from: oldData)
            try expect(migrated.decisionThreshold == 0.55, "Legacy threshold lost")
        }
        try check("saved migration remains independent of the old preference") {
            let migrated = try decoder.decode(ModeConfig.self, from: oldData)
            let persisted = try encoder.encode(migrated)
            legacyThreshold(0.95)
            let reloaded = try decoder.decode(ModeConfig.self, from: persisted)
            try expect(reloaded.decisionThreshold == 0.55, "Migration was not frozen")
        }
        try check("new modes use 0.70 rather than inheriting the legacy preference") {
            let draft = ModeConfigDraft(mode: .add, modeManager: ModeManager())
            try expect(draft.decisionThreshold == 0.7, "Wrong new-mode default")
        }
        let modes = [saved(0.6), saved(0.8)]
        try check("two saved modes round-trip with independent thresholds") {
            let restored = try decoder.decode([ModeConfig].self, from: encoder.encode(modes))
            try expect(restored.map(\.decisionThreshold) == [0.6, 0.8], "Modes share a threshold")
        }
        try check("editing or cancelling a draft does not mutate saved modes") {
            let manager = ModeManager()
            manager.configurations = modes
            var draft = ModeConfigDraft(mode: .edit(modes[0]), modeManager: manager)
            draft.decisionThreshold = 0.9
            try expect(manager.configurations.map(\.decisionThreshold) == [0.6, 0.8], "Draft leaked")
            let updated = draft.makeConfig(mode: .edit(modes[0]))
            try expect(updated.decisionThreshold == 0.9, "Draft value not saved")
            try expect(modes[1].decisionThreshold == 0.8, "Another mode changed")
        }
        try check("switching away from automatic preserves the configured threshold") {
            var draft = ModeConfigDraft(mode: .edit(modes[0]), modeManager: ModeManager())
            draft.enhancementStrategy = .always
            let stored = try decoder.decode(ModeConfig.self, from: encoder.encode(draft.makeConfig(mode: .edit(modes[0]))))
            try expect(stored.decisionThreshold == 0.6, "Hidden threshold was cleared")
        }
        try check("reset affects only the current draft and needs saving") {
            var draft = ModeConfigDraft(mode: .edit(modes[1]), modeManager: ModeManager())
            draft.decisionThreshold = DecisionSettings.defaultThreshold
            try expect(draft.decisionThreshold == 0.7 && modes[1].decisionThreshold == 0.8, "Reset leaked")
        }
        try check("invalid encoded thresholds fall back without dropping the mode") {
            for invalid: Any in [-0.1, 1.1, true, "0.8", NSNull()] {
                var object = legacy
                object["decisionThreshold"] = invalid
                let data = try JSONSerialization.data(withJSONObject: object)
                let decoded = try decoder.decode(ModeConfig.self, from: data)
                try expect(decoded.decisionThreshold == 0.7, "Invalid value accepted")
            }
        }
        try check("draft saving validates non-finite values") {
            let invalid = saved(.nan)
            try expect(invalid.decisionThreshold == 0.7, "Non-finite draft persisted")
        }
        try check("runtime snapshots use their mode, not the legacy global setting") {
            let snapshot = runtime(modes[0])
            legacyThreshold(0.1)
            try expect(snapshot.decisionThreshold == 0.6, "Snapshot changed")
            try expect(runtime(modes[1]).decisionThreshold == 0.8, "Wrong runtime threshold")
            try expect(snapshot.replacingPrompt(CustomPrompt(id: UUID())).decisionThreshold == 0.6, "Prompt replacement lost threshold")
        }
        for format in DecisionAPIFormat.allCases {
            for mode in modes {
                try await checkHTTP(mode: mode, format: format)
            }
        }
        print("Mode decision checks: \(count) passed")
    }

    static func checkHTTP(mode: ModeConfig, format: DecisionAPIFormat) async throws {
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["uv", "run", "--no-project", CommandLine.arguments[1]]
        server.standardOutput = output
        server.standardError = Pipe()
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let endpoint = URL(string: "https://127.0.0.1:\(port)/\(format == .systemOne ? "systemone" : "decisions")")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoopbackDecisionProtocol.self]
        let decisionSession = URLSession(configuration: config)
        let polishSession = URLSession(configuration: .ephemeral)
        defer { decisionSession.invalidateAndCancel(); polishSession.invalidateAndCancel() }
        let restored = try JSONDecoder().decode(ModeConfig.self, from: JSONEncoder().encode(mode))
        let snapshot = runtime(restored)
        let logs = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString)
        let client = BailianDecisionClient(session: decisionSession, developmentLog: DevelopmentDecisionLog(directory: logs))
        let result = try await snapshot.strategy.process(
            for: "custom",
            decide: {
                try await client.needsPolish(text: "custom", instructions: "cleanup", apiKey: "test-only-key",
                    endpoint: endpoint, model: "custom", format: format, threshold: snapshot.decisionThreshold)
            },
            enhance: {
                var request = URLRequest(url: base.appendingPathComponent("polish"))
                request.httpMethod = "POST"
                request.setValue("Bearer test-only-key", forHTTPHeaderField: "Authorization")
                request.httpBody = Data("{\"transcript\":\"custom\"}".utf8)
                let (data, _) = try await polishSession.data(for: request)
                return (try JSONSerialization.jsonObject(with: data) as! [String: String])["text"]!
            },
            onDecision: { route in
                if route.shouldEnhance {
                    Task { _ = try await polishSession.data(from: base.appendingPathComponent("release")) }
                }
            }
        )
        _ = try await polishSession.data(from: base.appendingPathComponent("release"))
        try expect(result == (mode.decisionThreshold == 0.6 ? "polished text" : nil), "Mode threshold did not affect HTTP routing")
        let file = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first!
        let line = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").last!
        let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        try expect(entry["threshold"] as? Double == mode.decisionThreshold, "Logged threshold mismatch")
        count += 1
        print("PASS: saved mode -> runtime -> local HTTP \(format.rawValue), threshold \(mode.decisionThreshold)")
    }
}
