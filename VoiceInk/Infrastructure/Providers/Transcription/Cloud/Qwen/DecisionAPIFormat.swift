import Foundation

enum DecisionAPIFormat: String, Codable, CaseIterable, Sendable {
    case systemOne, decisions

    var title: String {
        self == .systemOne ? "System One (/v1/systemone)" : "Decisions (/v1/decisions)"
    }
}
