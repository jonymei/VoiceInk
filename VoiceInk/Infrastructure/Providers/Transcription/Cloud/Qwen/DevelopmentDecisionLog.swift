import Foundation
import OSLog

final class DevelopmentDecisionLog: @unchecked Sendable {
    static let shared = DevelopmentDecisionLog()
    private let lock = NSLock()
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("VoiceInk/DevelopmentLogs", isDirectory: true)) {
        self.directory = directory
    }

    func record(_ event: String, fields: [String: Any]) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        do {
            let now = Date()
            var entry = fields
            entry["event"] = event
            entry["timestamp"] = ISO8601DateFormatter().string(from: now)
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0a)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
            let file = directory.appendingPathComponent("decisions-\(day).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DevelopmentDecisionLog")
                .error("Unable to write development decision data")
        }
        #endif
    }
}
