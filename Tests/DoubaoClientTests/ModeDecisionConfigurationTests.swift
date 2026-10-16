import Foundation
import XCTest

final class ModeDecisionConfigurationTests: XCTestCase {
    func testRealModeConfigurationsDraftsRuntimeAndLocalHTTP() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = tests.appendingPathComponent("ModeDecisionTests/run.py")
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let output = TestDirectories.unique("mode-tests")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "--no-project", runner.path, "--build-dir", build.path, "--output", output.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try result.write(to: output.appendingPathComponent("checks.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, result)
        XCTAssertTrue(result.contains("Mode decision checks: 14 passed"), result)
    }
}
