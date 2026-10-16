import Foundation
import Combine

struct CustomDecisionModel: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var endpoint: String
    var model: String
    var format: DecisionAPIFormat
}

final class CustomDecisionModelManager: ObservableObject {
    static let shared = CustomDecisionModelManager()
    @Published private(set) var models: [CustomDecisionModel]
    private let defaults = UserDefaults.standard
    private let storageKey = "customDecisionModels"

    private init() {
        models = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([CustomDecisionModel].self, from: $0)
        } ?? []
    }

    func save(_ model: CustomDecisionModel, apiKey: String) -> Bool {
        guard let url = URL(string: model.endpoint),
              (try? BailianDecisionClient.request(text: "", instructions: "", apiKey: apiKey,
                    endpoint: url, model: model.model, format: model.format)) != nil,
              !model.name.isEmpty,
              APIKeyManager.shared.saveCustomAIProviderAPIKey(apiKey, forProviderId: model.id)
        else { return false }
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        persist()
        return true
    }

    func remove(_ model: CustomDecisionModel) {
        models.removeAll { $0.id == model.id }
        APIKeyManager.shared.deleteCustomAIProviderAPIKey(forProviderId: model.id)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    func needsPolish(text: String, instructions: String, modelID: String?, threshold: Double) async throws -> Bool {
        let client = BailianDecisionClient()
        if let modelID, !modelID.isEmpty {
            guard let model = models.first(where: { $0.id.uuidString == modelID }),
                  let url = URL(string: model.endpoint),
                  let key = APIKeyManager.shared.getCustomAIProviderAPIKey(forProviderId: model.id)
            else { throw QwenASRError.configuration }
            return try await client.needsPolish(text: text, instructions: instructions, apiKey: key,
                                               endpoint: url, model: model.model, format: model.format, threshold: threshold)
        }
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: "Bailian") else {
            throw QwenASRError.missingAPIKey
        }
        return try await client.needsPolish(text: text, instructions: instructions, apiKey: key,
                                          configuration: .saved, threshold: threshold)
    }
}
