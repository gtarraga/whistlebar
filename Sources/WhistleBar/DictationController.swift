import AppKit
import AVFoundation
import ApplicationServices
import DictationCore
import SwiftUI

final class DictationController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum NotchSide: String { case left, right }
    enum PasteMode: String { case currentInput, startingInput, clipboardOnly }

    @Published var entries: [DictationEntry] = []
    @Published var message = "Loading Whistle…"
    @Published var modelReady = false
    @Published var keyboardEnabled = false
    @Published var recording = false
    @Published var busy = false
    @Published var microphoneLevel: Float = 0
    @Published var hudNotice: String?
    @Published var hudWarning = false
    @Published var notchEnabled = UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notchEnabled, forKey: "notchEnabled")
            onStateChange?()
        }
    }
    @Published var notchSide = NotchSide(rawValue: UserDefaults.standard.string(forKey: "notchSide") ?? "") ?? .left {
        didSet {
            UserDefaults.standard.set(notchSide.rawValue, forKey: "notchSide")
            onStateChange?()
        }
    }
    @Published var pasteMode = PasteMode(rawValue: UserDefaults.standard.string(forKey: "pasteMode") ?? "") ?? .currentInput {
        didSet { UserDefaults.standard.set(pasteMode.rawValue, forKey: "pasteMode") }
    }
    @Published var language: String = UserDefaults.standard.string(forKey: "language") ?? "" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var onStateChange: (() -> Void)?
    let history: HistoryStore
    private let engine = WhistleEngine()
    private let key = MicrophoneKey()
    private var recorder: AVAudioRecorder?
    private var current: DictationEntry?
    private var target: (pid: pid_t, element: AXUIElement)?
    private var pasteCancelled = false
    private var meterTimer: Timer?
    private var retentionTimer: Timer?
    private var noticeID = UUID()
    private var workspaceObservers: [NSObjectProtocol] = []

    init(directory: URL) throws {
        history = try HistoryStore(directory: directory)
        super.init()
        entries = history.entries
        pruneRecoveryAudio()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.pruneRecoveryAudio() }
        retentionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        key.onAction = { [weak self] action in
            switch action {
            case .start: self?.start()
            case .stop: self?.stop(resetGesture: false)
            }
        }
        key.onInterruption = { [weak self] in
            self?.message = "Keyboard monitoring was interrupted. Any recording was stopped and saved."
        }
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: notification, object: nil, queue: .main) { [weak self] _ in
                    self?.target = nil // Never paste on wake or into the login screen.
                    self?.pasteCancelled = true
                    self?.stop()
                })
        }
        engine.load { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.modelReady = true
                self.message = "Whistle is ready. Enable the microphone key to begin."
                if UserDefaults.standard.bool(forKey: "enableOnLaunch") { self.enableKeyboard() }
            case .failure(let error): self.message = error.localizedDescription
            }
            self.onStateChange?()
        }
    }

    deinit {
        retentionTimer?.invalidate()
        meterTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func pruneRecoveryAudio() {
        // Defer all cleanup while the recorder or inference/retry is using audio.
        guard !recording, !busy else { return }
        do { try history.pruneAudio() }
        catch { message = "Some recovery audio could not be removed: \(error.localizedDescription)" }
        objectWillChange.send() // Audio availability changed, not transcripts or statuses.
    }

    func enableKeyboard() {
        guard modelReady, !keyboardEnabled else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard allowed else {
                    self.message = "Allow Microphone access in System Settings → Privacy & Security."
                    return
                }
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                guard AXIsProcessTrustedWithOptions(options) else {
                    self.message = "Allow WhistleBar in Accessibility, then click Enable again."
                    return
                }
                if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
                do {
                    try self.key.enable()
                    self.keyboardEnabled = true
                    UserDefaults.standard.set(true, forKey: "enableOnLaunch")
                    self.message = "Ready. Hold the mic key, or double-tap for hands-free dictation."
                } catch { self.message = error.localizedDescription }
                self.onStateChange?()
            }
        }
    }

    func disableKeyboard() {
        stop()
        keyboardEnabled = false
        UserDefaults.standard.set(false, forKey: "enableOnLaunch")
        do {
            try key.disable()
            message = "Microphone key released back to macOS."
        } catch { message = error.localizedDescription }
        onStateChange?()
    }

    private func start() {
        guard modelReady, !busy, !recording, keyboardEnabled else { key.resetGesture(); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            message = "Microphone permission is missing. Re-enable access in System Settings."
            key.resetGesture()
            return
        }
        var entry = DictationEntry()
        do {
            pruneRecoveryAudio()
            try history.put(entry) // Index exists before audio capture begins.
            entries = history.entries
            pasteCancelled = false
            target = captureTarget()
            let recorder = try AVAudioRecorder(url: history.audioURL(for: entry), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw AppFailure.message("Could not start the microphone.") }
            self.recorder = recorder
            current = entry
            recording = true
            hudNotice = nil
            noticeID = UUID()
            microphoneLevel = 0
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.microphoneLevel = max(0, min(1, (recorder.averagePower(forChannel: 0) + 55) / 55))
            }
            meterTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            message = "Listening… Release after holding, or tap again in hands-free mode."
            onStateChange?()
        } catch {
            entry.status = .failed
            entry.message = error.localizedDescription
            persist(entry)
            message = error.localizedDescription
            target = nil
            key.resetGesture()
            showNotice("Microphone unavailable", warning: true)
        }
    }

    func stop(resetGesture: Bool = true) {
        if resetGesture { key.resetGesture() }
        guard recording, let entry = current else { return }
        recording = false
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        current = nil
        transcribe(entry, paste: true)
    }

    func retry(_ entry: DictationEntry) {
        guard !recording, !busy, modelReady else { return }
        pruneRecoveryAudio()
        guard history.hasAudio(for: entry) else {
            message = "Recovery audio is no longer available. The transcript is kept; Retry requires the recording."
            return
        }
        target = nil
        transcribe(entry, paste: false)
    }

    private func transcribe(_ entry: DictationEntry, paste: Bool) {
        busy = true
        message = "Transcribing on your Mac…"
        onStateChange?()
        var pending = entry
        pending.status = .transcribing
        pending.message = nil
        persist(pending)
        engine.transcribe(history.audioURL(for: entry), language: language) { [weak self] result in
            guard let self = self else { return }
            var finished = entry
            switch result {
            case .success(let transcript):
                finished.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                finished.language = transcript.language
                finished.status = .ready
                finished.message = finished.text.isEmpty ? "No speech detected. The recording is saved for retry." : nil
                if paste && !finished.text.isEmpty {
                    self.copy(finished.text)
                    finished.message = self.pasteTranscript()
                }
                self.message = finished.message ?? (paste ? "Copied and paste shortcut sent." : "Transcription recovered in history.")
                self.showNotice(finished.text.isEmpty ? "No speech detected" :
                    (paste ? (finished.message == nil ? "Copied · Paste sent" : "Copied · Paste manually") : "Recovered in history"),
                    warning: finished.text.isEmpty || (finished.message != nil && self.pasteMode != .clipboardOnly))
            case .failure(let error):
                finished.status = .failed
                finished.message = error.localizedDescription
                self.message = "Transcription failed. Your recording is saved; retry from history."
                self.showNotice("Saved · Retry in history", warning: true)
            }
            self.persist(finished)
            self.target = nil
            self.busy = false
            self.pruneRecoveryAudio()
            self.onStateChange?()
        }
    }

    private func showNotice(_ notice: String, warning: Bool) {
        hudNotice = notice
        hudWarning = warning
        let id = UUID()
        noticeID = id
        onStateChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + (warning ? 6 : 2.5)) { [weak self] in
            guard let self = self, self.noticeID == id else { return }
            self.hudNotice = nil
            self.onStateChange?()
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func delete(_ entry: DictationEntry) {
        guard !recording, !busy else { return }
        do {
            try history.delete(entry)
            entries = history.entries
        } catch { message = "Could not delete history: " + error.localizedDescription }
    }

    private func persist(_ entry: DictationEntry) {
        do { try history.put(entry) }
        catch { message = "History could not be saved: \(error.localizedDescription). Any captured audio remains in the history folder." }
        // Keep the transcript accessible in this window even if the disk write failed.
        entries = history.entries
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
        else { entries.insert(entry, at: 0) }
    }

    private func captureTarget() -> (pid: pid_t, element: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var focused: CFTypeRef?
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != "AXSecureTextField" else { return nil }
        return (app.processIdentifier, element)
    }

    private func pasteTranscript() -> String? {
        guard pasteMode != .clipboardOnly else {
            return "Copied only: automatic paste is off. Paste with ⌘V, or copy from history."
        }
        guard !pasteCancelled else {
            return "Copied only: dictation was interrupted by sleep or screen lock."
        }
        guard AXIsProcessTrusted(), let current = captureTarget() else {
            return "Copied only: the current input is unavailable or secure. Paste with ⌘V, or copy from history."
        }
        if pasteMode == .startingInput {
            guard let original = target, current.pid == original.pid, CFEqual(current.element, original.element) else {
                return "Copied only: focus changed. Starting input only is selected in Auto-paste settings."
            }
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return "Copied only: could not send the paste shortcut. Press ⌘V."
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return nil // Some apps reject synthetic paste; history is always available.
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Our own stop clears recording before AVFoundation calls back.
        guard recording else { return }
        audioRecorderEncodeErrorDidOccur(recorder, error: AppFailure.message(
            "The microphone stopped unexpectedly. Retry the saved recording from history."))
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard recording, var entry = current else { return }
        recording = false
        meterTimer?.invalidate()
        meterTimer = nil
        recorder.stop()
        self.recorder = nil
        current = nil
        target = nil
        key.resetGesture()
        entry.status = .failed
        entry.message = error?.localizedDescription ?? "Microphone recording was interrupted."
        persist(entry)
        message = entry.message ?? "Recording failed."
        showNotice("Recording interrupted", warning: true)
        onStateChange?()
    }

    func shutdown() throws {
        target = nil
        stop()
        try key.disable()
    }
}
