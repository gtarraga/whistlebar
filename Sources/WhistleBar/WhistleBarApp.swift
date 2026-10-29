import AppKit
import SwiftUI

@main
struct WhistleBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Keep the status button's menu handling, rather than intercepting clicks in SwiftUI.
final class StatusGlyphHost: NSHostingView<DictationStatusGlyph> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: DictationController?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var notch: NotchStatus?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance could fight over the global runtime and key mapping.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.WhistleBar").count > 1 {
            NSApp.terminate(nil)
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhistleBar", isDirectory: true)
        do {
            let controller = try DictationController(directory: directory)
            self.controller = controller
            notch = NotchStatus(controller: controller)
            controller.onStateChange = { [weak self] in self?.updateStatus() }
            let item = NSStatusBar.system.statusItem(withLength: 34)
            statusItem = item
            if let button = item.button {
                let glyph = StatusGlyphHost(rootView: DictationStatusGlyph(controller: controller))
                glyph.frame = button.bounds
                glyph.autoresizingMask = [.width, .height]
                button.addSubview(glyph)
            }
            appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.updateStatus()
            }
            let menu = NSMenu()
            menu.addItem(withTitle: "History & Settings…", action: #selector(showHistory), keyEquivalent: "")
            menu.addItem(withTitle: "Stop recording", action: #selector(stopRecording), keyEquivalent: "")
            menu.addItem(withTitle: "Copy last transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
            menu.addItem(withTitle: "Retry last recording", action: #selector(retryLastRecording), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit WhistleBar", action: #selector(quit), keyEquivalent: "q")
            for menuItem in menu.items { menuItem.target = self }
            item.menu = menu
            updateStatus()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "WhistleBar — History & Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(controller: controller))
            window.center()
            self.window = window
            showHistory()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot open dictation history"
            alert.informativeText = "\(error.localizedDescription)\n\nYour existing files have not been replaced. Find them at \(directory.path)."
            alert.addButton(withTitle: "Open history folder")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(directory) }
            NSApp.terminate(nil)
        }
    }

    private func updateStatus() {
        guard let controller = controller else { return }
        statusItem?.button?.setAccessibilityLabel("WhistleBar — \(controller.message)")
        statusItem?.button?.toolTip = controller.message
        notch?.update(appearance: statusItem?.button?.effectiveAppearance)
    }

    @objc private func showHistory() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func stopRecording() { controller?.stop() }
    @objc private func copyLastTranscript() {
        if let entry = controller?.entries.first(where: { !$0.text.isEmpty }) { controller?.copy(entry.text) }
    }
    @objc private func retryLastRecording() {
        if let entry = controller?.entries.first { controller?.retry(entry) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = controller else { return false }
        switch menuItem.action {
        case #selector(stopRecording): return controller.recording
        case #selector(copyLastTranscript): return controller.entries.contains { !$0.text.isEmpty }
        case #selector(retryLastRecording):
            let hasAudio = controller.entries.first.map { controller.history.hasAudio(for: $0) } ?? false
            menuItem.toolTip = hasAudio ? "Retry saves the result in history without pasting."
                : "The latest recording has no recovery audio."
            return hasAudio && controller.modelReady && !controller.busy && !controller.recording
        default: return true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = controller else { return .terminateNow }
        do { try controller.shutdown() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Could not restore the microphone key"
            alert.informativeText = "\(error.localizedDescription)\nRebooting also clears this temporary mapping."
            alert.addButton(withTitle: "Quit anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertSecondButtonReturn { return .terminateCancel }
        }
        // Any in-flight transcription is marked interrupted and retryable on next launch.
        return .terminateNow
    }
}
