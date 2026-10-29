import Foundation

public struct DictationEntry: Codable, Identifiable, Equatable {
    public enum Status: String, Codable { case recording, transcribing, ready, failed }
    public let id: UUID
    public let date: Date
    public var text: String
    public var language: String
    public var status: Status
    public var message: String?
    /// Missing on older entries: their audio is exempt from automatic cleanup.
    public var audioRetentionStartedAt: Date?
    public var audioFilename: String { id.uuidString + ".wav" }

    public init(id: UUID = UUID(), date: Date = Date()) {
        self.id = id
        self.date = date
        text = ""
        language = ""
        status = .recording
        audioRetentionStartedAt = date
    }
}

/// Audio is written directly to disk; the index is replaced atomically.
public final class HistoryStore {
    public let directory: URL
    public private(set) var entries: [DictationEntry]
    private var index: URL { directory.appendingPathComponent("history.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let index = directory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: index.path) {
            // Never silently replace an unreadable history index with an empty one.
            entries = try JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: index))
        } else {
            entries = []
        }
        var recovered = false
        for i in entries.indices where entries[i].status == .recording || entries[i].status == .transcribing {
            entries[i].status = .failed
            entries[i].message = "Interrupted. Retry the saved recording."
            recovered = true
        }
        if recovered { try save() }
    }

    public func audioURL(for entry: DictationEntry) -> URL {
        directory.appendingPathComponent(entry.audioFilename)
    }

    public func hasAudio(for entry: DictationEntry) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: entry).path)
    }

    /// Only new, inactive recordings are managed. Text/status/index never change.
    /// Empty successful transcripts use the failure window so silence stays retryable.
    public func pruneAudio(now: Date = Date()) throws {
        let successes = entries.filter {
            $0.audioRetentionStartedAt != nil && $0.status == .ready &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            if $0.date == $1.date { return $0.id.uuidString < $1.id.uuidString }
            return $0.date > $1.date
        }
        let retainedSuccesses = Set(successes.prefix(5).map(\.id))
        for entry in entries {
            guard let began = entry.audioRetentionStartedAt,
                  entry.status == .ready || entry.status == .failed else { continue }
            let success = entry.status == .ready && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let deadline = began.addingTimeInterval(success ? 24 * 60 * 60 : 7 * 24 * 60 * 60)
            if now >= deadline || (success && !retainedSuccesses.contains(entry.id)) {
                let audio = audioURL(for: entry)
                if hasAudio(for: entry) { try FileManager.default.removeItem(at: audio) }
            }
        }
    }

    public func put(_ entry: DictationEntry) throws {
        var next = entries
        if let i = next.firstIndex(where: { $0.id == entry.id }) {
            next[i] = entry
        } else {
            next.insert(entry, at: 0)
        }
        try save(next)
        entries = next
    }

    public func delete(_ entry: DictationEntry) throws {
        let next = entries.filter { $0.id != entry.id }
        let audio = audioURL(for: entry)
        if FileManager.default.fileExists(atPath: audio.path) {
            try FileManager.default.removeItem(at: audio)
        }
        // On an audio deletion failure, keep the entry so deletion can be retried.
        try save(next)
        entries = next
    }

    private func save(_ value: [DictationEntry]? = nil) throws {
        try JSONEncoder().encode(value ?? entries).write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }
}
