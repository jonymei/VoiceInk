import Foundation
import zlib

enum DoubaoStreamingError: Error, LocalizedError, Equatable {
    case invalidPacket
    case server(UInt32)
    case notConnected
    case invalidAudio
    case connectionFailed
    case timeout
    case http(Int)
    case transport(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPacket:
            return String(localized: "Doubao Speech returned an invalid streaming packet.")
        case .server(let code):
            return String(format: String(localized: "Doubao streaming recognition failed (code %lld). Check your speech service permissions and quota."), Int64(code))
        case .notConnected:
            return String(localized: "Doubao streaming recognition is not connected.")
        case .invalidAudio:
            return String(localized: "Doubao streaming recognition requires 16-bit mono PCM audio at 16 kHz.")
        case .connectionFailed:
            return String(localized: "Could not connect to Doubao streaming recognition. Check your API key, service access, and network.")
        case .timeout:
            return String(localized: "Doubao streaming recognition timed out waiting for the final result.")
        case .http(let status):
            return String(format: String(localized: "Doubao streaming connection failed (HTTP %lld). Check the speech API key and realtime service permissions."), Int64(status))
        case .transport(let code):
            return String(format: String(localized: "Doubao streaming network connection failed (URL error %lld)."), Int64(code))
        }
    }
}

enum DoubaoStreamingProtocol {
    struct Response: Equatable, Sendable {
        let text: String?
        let isFinal: Bool
    }

    static func configuration(customVocabulary: [String] = [], smoothing: Bool = false) throws -> Data {
        var options: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
            "enable_nonstream": true, "show_utterances": true,
            "enable_ddc": smoothing,
        ]
        var seen = Set<String>()
        let words = customVocabulary.compactMap { word -> [String: String]? in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return ["word": trimmed]
        }.prefix(100)
        if !words.isEmpty {
            let context = try JSONSerialization.data(withJSONObject: ["hotwords": Array(words)])
            options["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "voiceink"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": options,
        ])
        return packet(typeAndFlags: 0x10, serialization: 0x10, payload: payload)
    }

    static func audio(_ data: Data, isFinal: Bool = false) -> Data {
        packet(typeAndFlags: isFinal ? 0x22 : 0x20, serialization: 0, payload: data)
    }

    static func pcmAudio(fromWAV wav: Data) throws -> Data {
        guard wav.count <= DoubaoClient.maximumAudioBytes else { throw DoubaoError.audioTooLarge }
        guard wav.count >= 12, wav.prefix(4) == Data("RIFF".utf8), wav[8..<12] == Data("WAVE".utf8) else {
            throw DoubaoStreamingError.invalidAudio
        }
        func integer(_ start: Int, _ count: Int) -> UInt32 {
            wav[start..<start + count].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        var cursor = 12
        var validFormat = false
        var audio: Data?
        while cursor + 8 <= wav.count {
            let name = wav[cursor..<cursor + 4]
            let size = Int(integer(cursor + 4, 4))
            let start = cursor + 8
            guard start + size <= wav.count else { throw DoubaoStreamingError.invalidAudio }
            if name == Data("fmt ".utf8) {
                guard size >= 16 else { throw DoubaoStreamingError.invalidAudio }
                let format = integer(start, 2)
                let isPCM = format == 1 || (format == 0xfffe && size >= 40 && integer(start + 24, 4) == 1)
                validFormat = isPCM && integer(start + 2, 2) == 1 && integer(start + 4, 4) == 16000
                    && integer(start + 14, 2) == 16
            } else if name == Data("data".utf8) {
                audio = wav.subdata(in: start..<start + size)
            }
            cursor = start + size + size % 2
        }
        guard validFormat, let audio, !audio.isEmpty, audio.count.isMultiple(of: 2) else {
            throw DoubaoStreamingError.invalidAudio
        }
        return audio
    }

    static func parse(_ packet: Data) throws -> Response {
        let bytes = [UInt8](packet)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { throw DoubaoStreamingError.invalidPacket }
        let headerSize = Int(bytes[0] & 0x0f) * 4
        guard headerSize >= 4, headerSize <= bytes.count else { throw DoubaoStreamingError.invalidPacket }
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0f
        var cursor = headerSize
        func integer() throws -> UInt32 {
            guard cursor + 4 <= bytes.count else { throw DoubaoStreamingError.invalidPacket }
            defer { cursor += 4 }
            return bytes[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let sequence = flags & 1 != 0 ? Int32(bitPattern: try integer()) : 0
        if flags & 4 != 0 { _ = try integer() }
        if type == 0x0f { throw DoubaoStreamingError.server(try integer()) }
        guard type == 9, bytes[2] >> 4 == 1 else { throw DoubaoStreamingError.invalidPacket }
        let size = Int(try integer())
        guard size <= 4_000_000, cursor + size == bytes.count else { throw DoubaoStreamingError.invalidPacket }
        var payload = Data(bytes[cursor..<cursor + size])
        switch bytes[2] & 0x0f {
        case 0: break
        case 1: payload = try gunzip(payload)
        default: throw DoubaoStreamingError.invalidPacket
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DoubaoStreamingError.invalidPacket
        }
        let text: String?
        if let result = object["result"] as? [String: Any] {
            // The initial acknowledgement contains result.additions but no text.
            if let value = result["text"] {
                guard let value = value as? String else { throw DoubaoStreamingError.invalidPacket }
                text = value
            } else {
                text = nil
            }
        } else if let results = object["result"] as? [[String: Any]] {
            let texts = results.compactMap { $0["text"] as? String }
            guard texts.count == results.count else { throw DoubaoStreamingError.invalidPacket }
            text = texts.joined()
        } else if object["result"] == nil {
            text = nil
        } else {
            throw DoubaoStreamingError.invalidPacket
        }
        return Response(text: text, isFinal: flags & 2 != 0 || sequence < 0)
    }

    private static func packet(typeAndFlags: UInt8, serialization: UInt8, payload: Data) -> Data {
        var data = Data([0x11, typeAndFlags, serialization, 0])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DoubaoStreamingError.invalidPacket
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let bufferSize = buffer.count
            while true {
                let status = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(bufferSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw DoubaoStreamingError.invalidPacket }
                output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                guard output.count <= 4_000_000 else { throw DoubaoStreamingError.invalidPacket }
                if status == Z_STREAM_END { return output }
                guard stream.avail_in > 0 else { throw DoubaoStreamingError.invalidPacket }
            }
        }
    }
}
