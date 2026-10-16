import Foundation

enum EnhancementStrategy: String, Codable, CaseIterable {
    case always
    case automatic

    var displayName: String {
        switch self {
        case .always: return String(localized: "Always")
        case .automatic: return String(localized: "Automatic")
        }
    }

    enum Decision: Equatable, Sendable {
        case enhance, unchanged, fallback, polishFirst

        var shouldEnhance: Bool { self != .unchanged }
    }

    func decision(for text: String, using decide: () async throws -> Bool) async throws -> Decision {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unchanged }
        guard self == .automatic else { return .enhance }
        do { return try await decide() ? .enhance : .unchanged }
        catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return .fallback
        }
    }

    @MainActor
    func process<Output: Sendable>(
        for text: String,
        decide: @escaping @MainActor () async throws -> Bool,
        enhance: @escaping @MainActor () async throws -> Output,
        onDecision: (Decision) -> Void = { _ in }
    ) async throws -> Output? {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onDecision(.unchanged)
            return nil
        }
        guard self == .automatic else {
            onDecision(.enhance)
            let result = try await enhance()
            try Task.checkCancellation()
            return result
        }

        // Neither winner waits for the other request to cooperate with cancellation.
        let (events, continuation) = AsyncStream<Completion<Output>>.makeStream()
        let enhancementTask = Task {
            do { continuation.yield(.enhancement(.success(try await enhance()))) }
            catch { continuation.yield(.enhancement(.failure(error))) }
        }
        let decisionTask = Task {
            do { continuation.yield(.decision(.success(try await decision(for: text, using: decide)))) }
            catch { continuation.yield(.decision(.failure(error))) }
        }
        return try await withTaskCancellationHandler {
            defer {
                continuation.finish()
                decisionTask.cancel()
                enhancementTask.cancel()
            }
            var route: Decision?
            var enhancementError: Error?
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .decision(let result):
                    let decision = try result.get()
                    route = decision
                    onDecision(decision)
                    guard decision.shouldEnhance else { return nil }
                    if let enhancementError { throw enhancementError }
                case .enhancement(.success(let output)):
                    if route == nil { onDecision(.polishFirst) }
                    return output
                case .enhancement(.failure(let error)):
                    if error is CancellationError { throw error }
                    if route != nil { throw error }
                    enhancementError = error
                }
            }
            try Task.checkCancellation()
            throw CancellationError()
        } onCancel: {
            continuation.finish()
            decisionTask.cancel()
            enhancementTask.cancel()
        }
    }

    private enum Completion<Output: Sendable>: Sendable {
        case decision(Result<Decision, Error>)
        case enhancement(Result<Output, Error>)
    }
}
