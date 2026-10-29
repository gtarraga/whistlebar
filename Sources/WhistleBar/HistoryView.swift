import SwiftUI
import AppKit
import DictationCore

// SDK 27 also exports a State macro whose plugin is absent from Command Line Tools.
// Name the existing property-wrapper type explicitly instead of selecting that macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct HistoryView: View {
    @ObservedObject var controller: DictationController
    @ViewState private var search = ""
    @ViewState private var deleting: DictationEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("WhistleBar").font(.title2.bold())
                    Text("Your voice. On your Mac.").foregroundColor(.secondary)
                }
                Spacer()
                if controller.recording {
                    Button("Stop recording") { controller.stop() }.tint(.red)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.message, systemImage: controller.recording ? "mic.fill" : "info.circle")
                        .font(.callout).textSelection(.enabled)
                    HStack {
                        Button(controller.keyboardEnabled ? "Disable microphone key" : "Enable microphone key") {
                            if controller.keyboardEnabled { controller.disableKeyboard() }
                            else { controller.enableKeyboard() }
                        }
                        .disabled(!controller.modelReady || controller.busy || controller.recording)
                        Spacer()
                        Picker("Language", selection: $controller.language) {
                            Text("Auto-detect").tag("")
                            Text("English").tag("en")
                            Text("Español").tag("es")
                            Text("Français").tag("fr")
                            Text("Deutsch").tag("de")
                            Text("Italiano").tag("it")
                            Text("Nederlands").tag("nl")
                            Text("Polski").tag("pl")
                        }
                        .frame(width: 190).disabled(controller.recording || controller.busy)
                    }
                    HStack {
                        Toggle("Show notch indicator", isOn: $controller.notchEnabled)
                        Spacer()
                        Picker("Notch side", selection: $controller.notchSide) {
                            Text("Left").tag(DictationController.NotchSide.left)
                            Text("Right").tag(DictationController.NotchSide.right)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                        .disabled(!controller.notchEnabled || controller.recording || controller.busy)
                    }
                    Picker("Auto-paste", selection: $controller.pasteMode) {
                        Text("Current input").tag(DictationController.PasteMode.currentInput)
                        Text("Starting input only").tag(DictationController.PasteMode.startingInput)
                        Text("Clipboard only").tag(DictationController.PasteMode.clipboardOnly)
                    }
                    .disabled(controller.recording || controller.busy)
                    Text(controller.pasteMode == .currentInput
                         ? "Pastes wherever your cursor is when transcription finishes, even if you switch fields or apps."
                         : (controller.pasteMode == .startingInput
                            ? "Pastes only if the original app and input still have focus; otherwise copies only."
                            : "Copies the transcript without sending a paste shortcut."))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Hold the 🎤 key to talk; release to finish. Double-tap to keep listening, then tap once to finish.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !controller.keyboardEnabled {
                        Text("Enable temporarily remaps the microphone key to F13, preserving other mappings. Disable or quit restores it. Grant Microphone, Accessibility and Input Monitoring when prompted.")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("New recovery audio: latest 5 successful dictations for up to 24 hours; failed, interrupted or no-speech recordings for 7 days from capture. Text is kept. Older recordings are exempt until you delete them.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Dictation history").font(.headline)
                Spacer()
                Button("Open folder") { NSWorkspace.shared.open(controller.history.directory) }
            }
            TextField("Search transcripts", text: $search).textFieldStyle(.roundedBorder)
            if controller.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundColor(.secondary)
                    Text("Your dictations will appear here.").font(.headline)
                    Text("Copy a transcript or retry a saved recording if anything goes wrong.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.entries.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { entry in
                            entryView(entry)
                        }
                    }
                }
            }
            Divider()
            Text("Offline transcription · Audio uses about 1.9 MB/min and is cleaned up when idle. Clipboard text is accessible to other apps and may sync through Universal Clipboard.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(minWidth: 580, minHeight: 620)
        .alert("Delete this dictation and recording?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = deleting { controller.delete(entry) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This cannot be undone.") }
    }

    private func entryView(_ entry: DictationEntry) -> some View {
        let audioAvailable = controller.history.hasAudio(for: entry)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                Text(entry.language.isEmpty ? entry.status.rawValue.capitalized : entry.language.uppercased())
            }
            .font(.caption).foregroundColor(.secondary)
            if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let message = entry.message { Text(message).font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
            if !audioAvailable {
                Text("Audio no longer available. Text is kept; Retry and Reveal require the recording.")
                    .font(.caption).foregroundColor(.secondary)
            } else if entry.audioRetentionStartedAt == nil {
                Text("Older recording · audio kept until you delete it.")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("Copy") { controller.copy(entry.text) }.disabled(entry.text.isEmpty)
                Button("Retry") { controller.retry(entry) }
                    .disabled(!audioAvailable || controller.busy || controller.recording || !controller.modelReady)
                    .help(audioAvailable ? "Transcribe the saved recording again" : "Recovery audio is no longer available")
                Button("Reveal audio") { NSWorkspace.shared.activateFileViewerSelecting([controller.history.audioURL(for: entry)]) }
                    .disabled(!audioAvailable || controller.recording || controller.busy)
                    .help(audioAvailable ? "Show the saved recording in Finder" : "Recovery audio is no longer available")
                Spacer()
                Button(role: .destructive) { deleting = entry } label: { Image(systemName: "trash") }
                    .help("Delete transcript and audio").disabled(controller.busy || controller.recording)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
