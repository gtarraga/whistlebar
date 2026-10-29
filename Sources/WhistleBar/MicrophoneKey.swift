import AppKit
import ApplicationServices
import DictationCore

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Remap the reserved Consumer/Voice Command key to F13, preserving other mappings.
/// Only an explicit setup click enables this; no root access or login agent is used.
final class MicrophoneKey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = DictationGesture()
    private var heldKey: Int64?
    private var ownsMapping = false
    private let sourceUsage: UInt64 = 0xC000000CF
    private let destinationUsage: UInt64 = 0x700000068
    var onAction: ((DictationGesture.Action) -> Void)?
    var onInterruption: (() -> Void)?

    func enable() throws {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MicrophoneKey>.fromOpaque(context).takeUnretainedValue()
                    .handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw AppFailure.message("Allow Accessibility and Input Monitoring in System Settings, then quit and reopen WhistleBar.")
        }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        do {
            var mappings = try readMappings()
            if let existing = mappings.first(where: { ($0["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value == sourceUsage }) {
                guard (existing["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value == destinationUsage else {
                    throw AppFailure.message("Your microphone key already has a custom mapping. Remove it before enabling WhistleBar; other mappings have not been changed.")
                }
                // An identical mapping may remain after a crash. Explicit enable adopts it.
            } else {
                mappings.append(["HIDKeyboardModifierMappingSrc": sourceUsage,
                                 "HIDKeyboardModifierMappingDst": destinationUsage])
                try writeMappings(mappings)
            }
            ownsMapping = true
        } catch {
            try? disable()
            throw error
        }
    }

    func disable() throws {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        heldKey = nil
        gesture.cancel().forEach { onAction?($0) }
        if ownsMapping {
            let current = try readMappings()
            let filtered = current.filter {
                !(($0["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value == sourceUsage
                  && ($0["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value == destinationUsage)
            }
            try writeMappings(filtered)
            ownsMapping = false
        }
    }

    func resetGesture() {
        _ = gesture.cancel()
        // Keep heldKey until its release so it doesn't leak into the focused app.
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            heldKey = nil
            emit(gesture.cancel())
            DispatchQueue.main.async { [weak self] in self?.onInterruption?() }
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 96 || code == 105 else { return Unmanaged.passUnretained(event) }
        let now = Double(event.timestamp) / 1_000_000_000
        if type == .keyDown {
            if heldKey != nil { return nil }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return Unmanaged.passUnretained(event) }
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty else { return Unmanaged.passUnretained(event) }
            heldKey = code
            emit(gesture.press(at: now))
        } else if type == .keyUp {
            guard heldKey == code else { return Unmanaged.passUnretained(event) }
            heldKey = nil
            emit(gesture.release(at: now))
            DispatchQueue.main.asyncAfter(deadline: .now() + gesture.doubleTapWindow + 0.01) { [weak self] in
                guard let self = self else { return }
                self.gesture.tick(at: ProcessInfo.processInfo.systemUptime).forEach { self.onAction?($0) }
            }
        }
        return nil
    }

    private func emit(_ actions: [DictationGesture.Action]) {
        guard !actions.isEmpty else { return }
        // Never perform audio setup, focus queries or disk IO inside the global event tap.
        // A slow callback stalls system input and macOS disables it after a timeout.
        DispatchQueue.main.async { [weak self] in actions.forEach { self?.onAction?($0) } }
    }

    private func hidutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", "keyboard"] + arguments
        let output = Pipe()
        process.standardOutput = output
        // Do not wait before draining: a large existing mapping can fill the pipe.
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppFailure.message("macOS could not update the microphone key mapping.")
        }
        return data
    }

    private func readMappings() throws -> [[String: Any]] {
        let data = try hidutil(["--get", "UserKeyMapping"])
        return try Self.parseMappings(data)
    }

    static func parseMappings(_ data: Data) throws -> [[String: Any]] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("RegistryID") {
            // macOS 27 reports one property per matching keyboard service. Only a
            // uniform set can safely be updated by a single hidutil --set command.
            let row = try NSRegularExpression(pattern: "(?m)^[0-9a-fA-F]+[ \\t]+UserKeyMapping[ \\t]+")
            let matches = row.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !matches.isEmpty else {
                throw AppFailure.message("No keyboard mappings could be read; nothing was changed.")
            }
            let string = text as NSString
            var common: [[String: Any]]?
            for (index, match) in matches.enumerated() {
                let start = NSMaxRange(match.range)
                let end = index + 1 < matches.count ? matches[index + 1].range.location : string.length
                let value = string.substring(with: NSRange(location: start, length: end - start))
                let mappings = try parseMappings(Data(value.utf8))
                if let common = common, !(common as NSArray).isEqual(to: mappings) {
                    throw AppFailure.message("Your keyboards have different custom mappings. WhistleBar cannot safely change them; nothing was changed.")
                }
                common = mappings
            }
            return common ?? []
        }
        if text == "(null)" || text == "null" { return [] }
        // hidutil --get uses an OpenStep property list, not necessarily JSON.
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let mappings = value as? [[String: Any]] else {
            throw AppFailure.message("Cannot read your keyboard mappings safely; nothing was changed.")
        }
        // OpenStep numbers may be returned as strings. Normalize before JSON --set.
        return try mappings.map { mapping in
            var normalized = mapping
            for key in ["HIDKeyboardModifierMappingSrc", "HIDKeyboardModifierMappingDst"] {
                guard let value = mapping[key] else {
                    throw AppFailure.message("Unrecognized keyboard mapping; nothing was changed.")
                }
                let text = String(describing: value)
                let number = text.lowercased().hasPrefix("0x")
                    ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
                guard let number = number else {
                    throw AppFailure.message("Unrecognized keyboard mapping; nothing was changed.")
                }
                normalized[key] = number
            }
            return normalized
        }
    }

    private func writeMappings(_ mappings: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["UserKeyMapping": mappings], options: [.sortedKeys])
        _ = try hidutil(["--set", String(decoding: data, as: UTF8.self)])
    }
}
