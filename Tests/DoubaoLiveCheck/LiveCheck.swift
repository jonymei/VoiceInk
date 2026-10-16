import Foundation

@main
enum DoubaoLiveCheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("Usage: doubao-live-check <authorized-env-file> <synthetic-wav-file>")
            exit(2)
        }
        do {
            let contents = try String(contentsOfFile: arguments[1], encoding: .utf8)
            let key = contents.components(separatedBy: .newlines).compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "DOUBAO_VOICE_API_KEY" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.first
            guard let key, !key.isEmpty else {
                print("LIVE_RESULT: missing speech credential")
                exit(2)
            }
            let wav = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let text = try await DoubaoStreamingClient.transcribeWAV(wav, apiKey: key, timeout: 45)
            print("LIVE_RESULT: success; final transcript characters=\(text.count); endpoint=bigmodel_async; resource=volc.seedasr.sauc.duration")
        } catch let error as DoubaoStreamingError {
            print("LIVE_RESULT: failed; \(error.localizedDescription)")
            exit(1)
        } catch {
            print("LIVE_RESULT: failed; no credentials, audio, or response content logged")
            exit(1)
        }
    }
}
