import Foundation
import XCTest
@testable import EnhancementPolicy

@MainActor
final class ParallelEnhancementTests: XCTestCase {
    func testNegativeDecisionReturnsBeforeUncooperativePolishAndDiscardsLateResult() async throws {
        let decision = TestGate<Bool>()
        let polish = TestGate<String>()
        let returned = expectation(description: "Original returned before polish finishes")
        var observed: EnhancementStrategy.Decision?
        let task = Task {
            let result = try await EnhancementStrategy.automatic.process(
                for: "clean text", decide: { try await decision.wait() },
                enhance: { try await polish.wait() }, onDecision: { observed = $0 }
            )
            returned.fulfill()
            return result
        }
        await fulfillment(of: [decision.started, polish.started], timeout: 2)
        decision.resolve(.success(false))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(observed, .unchanged)
        polish.resolve(.success("late polish must not appear"))
        let result = try await task.value
        XCTAssertNil(result)
        await fulfillment(of: [polish.finished], timeout: 2)
        XCTAssertTrue(polish.wasCancelled)
    }

    func testEarlyPolishReturnsBeforePositiveDecisionWithoutStartingAnotherRequest() async throws {
        let decision = TestGate<Bool>()
        let polish = TestGate<String>()
        let returned = expectation(description: "Polish returned before decision finishes")
        var routes: [EnhancementStrategy.Decision] = []
        let task = Task {
            let result = try await EnhancementStrategy.automatic.process(
                for: "um text", decide: { try await decision.wait() },
                enhance: { try await polish.wait() }, onDecision: { routes.append($0) }
            )
            returned.fulfill()
            return result
        }
        await fulfillment(of: [decision.started, polish.started], timeout: 2)
        polish.resolve(.success("polished text"))
        await fulfillment(of: [returned], timeout: 2)
        let result = try await task.value
        XCTAssertEqual(result, "polished text")
        XCTAssertEqual(routes, [.polishFirst])
        XCTAssertEqual(polish.calls, 1)
        decision.resolve(.success(true))
        await fulfillment(of: [decision.finished], timeout: 2)
        XCTAssertTrue(decision.wasCancelled)
        XCTAssertEqual(routes, [.polishFirst])
    }

    func testEarlyPolishIsNotReplacedByLateNegativeDecision() async throws {
        let decision = TestGate<Bool>()
        let polish = TestGate<String>()
        let returned = expectation(description: "Polish returned before late negative decision")
        var routes: [EnhancementStrategy.Decision] = []
        let task = Task {
            let result = try await EnhancementStrategy.automatic.process(
                for: "clean text", decide: { try await decision.wait() }, enhance: { try await polish.wait() },
                onDecision: { routes.append($0) }
            )
            returned.fulfill()
            return result
        }
        await fulfillment(of: [decision.started, polish.started], timeout: 2)
        polish.resolve(.success("polished text"))
        await fulfillment(of: [returned], timeout: 2)
        let result = try await task.value
        XCTAssertEqual(result, "polished text")
        decision.resolve(.success(false))
        await fulfillment(of: [decision.finished], timeout: 2)
        XCTAssertTrue(decision.wasCancelled)
        XCTAssertEqual(routes, [.polishFirst])
    }

    func testPositiveDecisionStillWaitsForRunningPolish() async throws {
        let polish = TestGate<String>()
        let routed = expectation(description: "Positive decision received")
        let task = Task {
            try await EnhancementStrategy.automatic.process(
                for: "text", decide: { true }, enhance: { try await polish.wait() },
                onDecision: { route in
                    XCTAssertEqual(route, .enhance)
                    routed.fulfill()
                }
            )
        }
        await fulfillment(of: [polish.started, routed], timeout: 2)
        polish.resolve(.success("polished text"))
        let result = try await task.value
        XCTAssertEqual(result, "polished text")
    }

    func testDecisionFailureUsesAlreadyRunningPolish() async throws {
        let decision = TestGate<Bool>()
        let polish = TestGate<String>()
        let routed = expectation(description: "Fallback selected")
        let task = Task {
            try await EnhancementStrategy.automatic.process(
                for: "text", decide: { try await decision.wait() }, enhance: { try await polish.wait() },
                onDecision: { route in
                    XCTAssertEqual(route, .fallback)
                    routed.fulfill()
                }
            )
        }
        await fulfillment(of: [decision.started, polish.started], timeout: 2)
        decision.resolve(.failure(TestFailure.request))
        await fulfillment(of: [routed], timeout: 2)
        polish.resolve(.success("fallback polish"))
        let result = try await task.value
        XCTAssertEqual(result, "fallback polish")
        XCTAssertEqual(polish.calls, 1)
    }

    func testPolishFailureIsIgnoredIfDecisionSaysUnchanged() async throws {
        let result: String? = try await EnhancementStrategy.automatic.process(
            for: "clean text", decide: { false }, enhance: { throw TestFailure.request }
        )
        XCTAssertNil(result)
    }

    func testPolishFailureIsPropagatedIfDecisionSaysEnhance() async {
        do {
            let _: String? = try await EnhancementStrategy.automatic.process(
                for: "text", decide: { true }, enhance: { throw TestFailure.request }
            )
            XCTFail("Expected polish failure")
        } catch {
            XCTAssertEqual(error as? TestFailure, .request)
        }
    }

    func testCancellationCancelsBothRequestsWithoutPublishingDecision() async {
        let decisionStarted = expectation(description: "Decision started")
        let polishStarted = expectation(description: "Polish started")
        let decisionCancelled = expectation(description: "Decision cancelled")
        let polishCancelled = expectation(description: "Polish cancelled")
        let task = Task {
            try await EnhancementStrategy.automatic.process(
                for: "text",
                decide: {
                    decisionStarted.fulfill()
                    do { try await Task.sleep(for: .seconds(60)); return true }
                    catch { decisionCancelled.fulfill(); throw error }
                },
                enhance: {
                    polishStarted.fulfill()
                    do { try await Task.sleep(for: .seconds(60)); return "polish" }
                    catch { polishCancelled.fulfill(); throw error }
                },
                onDecision: { _ in XCTFail("Cancellation must not publish a route") }
            )
        }
        await fulfillment(of: [decisionStarted, polishStarted], timeout: 2)
        task.cancel()
        await fulfillment(of: [decisionCancelled, polishCancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationReturnsWithoutWaitingForEitherUncooperativeRequest() async {
        let decision = TestGate<Bool>()
        let polish = TestGate<String>()
        let returned = expectation(description: "Cancellation returned promptly")
        let task = Task {
            defer { returned.fulfill() }
            return try await EnhancementStrategy.automatic.process(
                for: "text", decide: { try await decision.wait() }, enhance: { try await polish.wait() },
                onDecision: { _ in XCTFail("Cancellation must not publish a route") }
            )
        }
        await fulfillment(of: [decision.started, polish.started], timeout: 2)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        decision.resolve(.success(false))
        polish.resolve(.success("late polish"))
        await fulfillment(of: [decision.finished, polish.finished], timeout: 2)
    }

    func testAlwaysAndEmptyInputDoNotStartDecision() async throws {
        let always = try await EnhancementStrategy.always.process(
            for: "text", decide: { XCTFail("Unexpected decision"); return false }, enhance: { "polish" }
        )
        XCTAssertEqual(always, "polish")
        let empty: String? = try await EnhancementStrategy.automatic.process(
            for: " \n", decide: { XCTFail("Unexpected decision"); return true },
            enhance: { XCTFail("Unexpected polish"); return "polish" }
        )
        XCTAssertNil(empty)
    }
}

private enum TestFailure: Error { case request }

@MainActor
private final class TestGate<Value: Sendable> {
    let started = XCTestExpectation(description: "Request started")
    let finished = XCTestExpectation(description: "Request finished")
    private var continuation: CheckedContinuation<Value, Error>?
    private(set) var calls = 0
    private(set) var wasCancelled = false

    func wait() async throws -> Value {
        calls += 1
        defer {
            wasCancelled = Task.isCancelled
            finished.fulfill()
        }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
