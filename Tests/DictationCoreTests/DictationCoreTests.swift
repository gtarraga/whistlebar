import Foundation
import Testing
import DictationCore

struct DictationCoreTests {
    @Test func holdRecordsImmediatelyAndStopsOnRelease() {
        var key = DictationGesture()
        #expect(key.press(at: 10) == [.start])
        #expect(key.press(at: 10.2).isEmpty)
        #expect(key.release(at: 10.7) == [.stop])
        #expect(key.tick(at: 11.2).isEmpty)
    }

    @Test func doubleTapLatchesAcrossReleaseAndStopsAtNextPress() {
        var key = DictationGesture()
        #expect(key.press(at: 1) == [.start])
        #expect(key.release(at: 1.09).isEmpty)
        #expect(key.press(at: 1.3).isEmpty)
        #expect(key.release(at: 1.4).isEmpty)
        #expect(key.tick(at: 60).isEmpty)
        #expect(key.press(at: 61) == [.stop])
        #expect(key.release(at: 61.1).isEmpty)
        #expect(key.press(at: 62) == [.start])
    }

    @Test func singleTapAndDoubleTapBoundary() {
        var key = DictationGesture()
        #expect(key.press(at: 0) == [.start])
        #expect(key.release(at: 0.1).isEmpty)
        #expect(key.tick(at: 0.44).isEmpty)
        #expect(key.tick(at: 0.46) == [.stop])
        #expect(key.press(at: 0.47) == [.start])
        #expect(key.release(at: 0.72) == [.stop])
    }

    @Test func lateSecondPressWithoutTimerTickStartsANewSession() {
        var key = DictationGesture()
        _ = key.press(at: 0)
        _ = key.release(at: 0.05)
        #expect(key.press(at: 0.5) == [.stop, .start])
        #expect(key.cancel() == [.stop])
        #expect(key.cancel().isEmpty)
        #expect(key.release(at: 1).isEmpty)
    }

    @Test func historySurvivesRestartAndRecoversInterruptedAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        var done = DictationEntry(date: Date(timeIntervalSince1970: 123))
        done.text = "Hola, això és una prova."
        done.status = .ready
        done.language = "es"
        try store.put(done)
        var pending = DictationEntry()
        pending.status = .transcribing
        let audio = Data([1, 3, 7])
        try audio.write(to: store.audioURL(for: pending))
        try store.put(pending)
        let restored = try HistoryStore(directory: dir)
        #expect(restored.entries.map(\.id) == [pending.id, done.id])
        #expect(restored.entries[0].status == .failed)
        #expect(restored.entries[0].message != nil)
        #expect(restored.entries[1] == done)
        #expect(try Data(contentsOf: restored.audioURL(for: pending)) == audio)
        try restored.delete(restored.entries[0])
        #expect(!FileManager.default.fileExists(atPath: restored.audioURL(for: pending).path))
        #expect(try HistoryStore(directory: dir).entries == [done])
    }

    @Test func corruptHistoryIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        let original = Data("broken index".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try HistoryStore(directory: dir) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func audioExpiryBoundariesPreserveTextLegacySilenceAndActiveWork() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let now = Date(timeIntervalSince1970: 2_000_000)
        // Asymmetric cases distinguish inclusive deadlines, silence, and active retries.
        let fixtures: [(TimeInterval, DictationEntry.Status, String, Bool)] = [
            (86_399, .ready, "Fresh success", true),
            (86_400, .ready, "Boundary success", false),
            (604_799, .failed, "", true),
            (604_800, .failed, "", false),
            (86_401, .ready, " \n", true),
            (604_800, .ready, "", false),
            (700_000, .recording, "", true),
            (700_000, .transcribing, "Retried text", true)
        ]
        var entries: [DictationEntry] = []
        for (age, status, text, _) in fixtures {
            var entry = DictationEntry(date: now.addingTimeInterval(-age))
            entry.status = status
            entry.text = text
            try store.put(entry)
            try Data([2, 4, 8]).write(to: store.audioURL(for: entry))
            entries.append(entry)
        }
        var legacy = DictationEntry(date: now.addingTimeInterval(-900_000))
        legacy.status = .ready
        legacy.text = "Legacy must stay"
        legacy.audioRetentionStartedAt = nil
        let legacyData = try JSONEncoder().encode(legacy)
        #expect(!(String(decoding: legacyData, as: UTF8.self).contains("audioRetentionStartedAt")))
        let decodedLegacy = try JSONDecoder().decode(DictationEntry.self, from: legacyData)
        #expect(decodedLegacy.audioRetentionStartedAt == nil)
        try store.put(decodedLegacy)
        try Data([1]).write(to: store.audioURL(for: legacy))
        let index = dir.appendingPathComponent("history.json")
        let originalIndex = try Data(contentsOf: index)
        try store.pruneAudio(now: now)
        for (entry, fixture) in zip(entries, fixtures) {
            #expect(store.hasAudio(for: entry) == fixture.3)
        }
        #expect(store.hasAudio(for: legacy))
        #expect(try Data(contentsOf: index) == originalIndex)
        #expect(store.entries.first(where: { $0.id == entries[1].id }) == entries[1])
        // A crash releases active-work protection; an old interrupted retry expires.
        let restarted = try HistoryStore(directory: dir)
        #expect(restarted.entries.first(where: { $0.id == entries[7].id })?.status == .failed)
        try restarted.pruneAudio(now: now)
        #expect(!restarted.hasAudio(for: entries[7]))
        #expect(restarted.hasAudio(for: legacy))
    }

    @Test func onlyNewestFiveSuccessfulNewRecordingsKeepAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let successes = (0..<6).map { i -> DictationEntry in
            var entry = DictationEntry(date: now.addingTimeInterval(-Double(i) * 60))
            entry.status = .ready
            entry.text = "Transcript \(i)"
            return entry
        }
        for i in [3, 0, 5, 1, 4, 2] {
            try store.put(successes[i])
            try Data([UInt8(i)]).write(to: store.audioURL(for: successes[i]))
        }
        var silence = DictationEntry(date: now)
        silence.status = .ready
        try store.put(silence)
        try Data([0]).write(to: store.audioURL(for: silence))
        var legacy = DictationEntry(date: now)
        legacy.audioRetentionStartedAt = nil
        legacy.status = .ready
        legacy.text = "Legacy does not count toward five"
        try store.put(legacy)
        try Data([9]).write(to: store.audioURL(for: legacy))
        let original = store.entries
        try store.pruneAudio(now: now)
        try store.pruneAudio(now: now) // Repeated cleanup is harmless.
        #expect(successes.prefix(5).allSatisfy { store.hasAudio(for: $0) })
        #expect(!store.hasAudio(for: successes[5]))
        #expect(store.hasAudio(for: silence))
        #expect(store.hasAudio(for: legacy))
        #expect(store.entries == original)
        #expect(try HistoryStore(directory: dir).entries == original)
    }
}
