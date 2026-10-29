import AVFoundation
import CNeedle

struct Transcript: Decodable {
    let text: String
    let language: String
}

/// Needle is process-global and not thread-safe. Every call stays on this queue.
final class WhistleEngine {
    private let queue = DispatchQueue(label: "WhistleBar.inference", qos: .userInitiated)
    private var model: Data?

    func load(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> Void in
                guard let url = Bundle.main.url(forResource: "whistle", withExtension: "cact") else {
                    throw AppFailure.message("Whistle model missing. Rebuild using scripts/build-app.sh.")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                self.model = data // Keep storage alive for the entire runtime lifetime.
                let code = data.withUnsafeBytes { bytes in
                    needle_load(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count))
                }
                guard code >= 0 else { throw self.runtimeError() }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func transcribe(_ url: URL, language: String, completion: @escaping (Result<Transcript, Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> Transcript in
                let file = try AVAudioFile(forReading: url)
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                      file.length > 0, file.length <= Int64(Int32.max),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw AppFailure.message("The recording is empty or is not 16 kHz mono audio.")
                }
                try file.read(into: buffer)
                guard let samples = buffer.floatChannelData?[0] else {
                    throw AppFailure.message("Could not read the recording's audio samples.")
                }
                // Output grows with duration. 1 KB/s comfortably covers text and JSON escaping.
                let capacity = max(65_536, Int(buffer.frameLength) / 16 + 65_536)
                guard capacity <= Int(Int32.max) else { throw AppFailure.message("Recording is too long to transcribe.") }
                var output = [CChar](repeating: 0, count: capacity)
                let code = language.withCString { lang in
                    needle_transcribe(samples, Int32(buffer.frameLength), language.isEmpty ? nil : lang,
                                      nil, 0, &output, Int32(output.count))
                }
                guard code >= 0 else { throw self.runtimeError() }
                return try JSONDecoder().decode(Transcript.self, from: Data(String(cString: output).utf8))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func runtimeError() -> AppFailure {
        .message(needle_last_error().map { String(cString: $0) } ?? "Whistle could not transcribe this recording.")
    }
}
