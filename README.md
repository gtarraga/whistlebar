# WhistleBar

A small native macOS menu-bar dictation app using [Cactus Whistle](https://cactuscompute.com/blog/whistle).
SwiftUI/AppKit + AVFoundation, with the CPU inference engine linked directly into the app.
No Electron, Python, server, account, or runtime downloads. The bundled model is 16.9 MB.

**Target:** Apple Silicon Mac, macOS 26 Tahoe or newer. Designed for the microphone key
on a 14-inch MacBook Pro. The pinned official static runtime declares macOS 26.0 as its
minimum deployment version; earlier macOS versions need a different runtime build.
Intel builds are not included.

## Build and install

On your Mac, install Xcode 26 Command Line Tools (`xcode-select --install`) if needed.
From this repository's folder:

```sh
bash scripts/build-app.sh
```

This downloads the official engine and model at pinned revisions, verifies their SHA-256
checksums, runs the tests, builds a release app, and ad-hoc signs it. Output:
`dist/WhistleBar.app` and `dist/WhistleBar.zip`. The first build needs Internet; the app does not.
You need a macOS 26+ SDK (Xcode 26+ tools). For a local build, a paid Apple developer account is not required.

1. Quit Wispr Flow (and any other app bound to the microphone key).
2. Copy `dist/WhistleBar.app` into `/Applications`, then open it there.
3. Click **Enable microphone key** in History & Settings.
4. Grant **Microphone**, **Accessibility**, and **Input Monitoring** in System Settings →
   Privacy & Security. Click Enable again after granting access; macOS may require you to
   quit and reopen the app after Input Monitoring changes.
5. Put your cursor in another app's text input and dictate.

The build is locally signed, **not notarized**. Use System Settings → Privacy & Security →
Open Anyway if macOS blocks a downloaded build. Rebuilds can require re-granting permissions.
Set `SIGNING_IDENTITY` to your Developer ID certificate to sign with your own identity instead.

## Controls and status

| Gesture | Result |
| --- | --- |
| Hold microphone/F5 key for ≥250 ms | Records immediately; release stops and transcribes |
| Double-tap (within 350 ms of the first release) | Keeps recording after release; tap once more to finish |
| Single quick tap | Records a short clip, finishing after the double-tap window |
| Menu bar → Stop recording | Stops either recording mode |
| Menu bar → Copy last transcript | Copies the latest nonempty transcript |
| Menu bar → Retry last recording | Retranscribes the latest recording into history, without pasting |

Five straight rounded equalizer bars sit directly on the menu bar, immediately beside the
physical camera cutout: no black extension, background, border, label, dot, or timer. Choose
**Left / Right** beside **Show notch indicator** in History & Settings; Left is the default.
Uncheck **Show notch indicator** to turn the notch UI off entirely, including while recording
or processing. This does not disable dictation, pasting, or the menu-bar controls. The switch
and side persist across launches; the switch defaults on for existing users, and its side
control is disabled while the notch is off. Even when enabled, the notch is hidden while idle.
Listening gently pulses and
reacts to the microphone level; Transcribing replaces it with a small teal spinner (2.5-point
stroke). The persistent, clickable menu-bar item uses the exact same five-bar glyph and animation,
not a separate red microphone symbol. Detailed results/errors remain in history and the menu-bar
tooltip. Orange is a brief warning for no speech, transcription/recording failure or skipped
automatic paste, not a recording or processing state. Bars follow the menu-bar appearance, without
outlines. Reduce Motion stops the animation while microphone level can still change bar height.
The app bundle includes a five-bar teal icon for Finder and System Settings; the History & Settings
header displays that exact application icon instead of a separate waveform symbol. As a menu-bar app,
WhistleBar intentionally has no permanent Dock icon. The build generates every icon resolution
with `scripts/generate-icon.swift`; there is no external asset-generation dependency.

The single transparent 38-point-wide panel is nonactivating and click-through. Its edge comes
from `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, and its height from the safe
area. The entire camera cutout stays empty; nothing hangs below it. A notchless display uses
the selected side of top center in the menu-bar band. No microphone-level polling runs idle.

On success, the transcript replaces the clipboard. **Auto-paste** in History & Settings has three
persisted choices:

- **Current input** (default): sends ⌘V to the input focused when transcription finishes,
  even if you switch fields or applications while dictating. Check your cursor before finishing.
- **Starting input only**: sends ⌘V only if the same app and accessibility-focused element
  still have focus. Otherwise copies only, with an explanation.
- **Clipboard only**: never sends a paste shortcut; paste manually when you want.

No mode refocuses an app or pastes into secure password fields. Sleep/screen lock cancels
automatic paste, and an unavailable/inaccessible input falls back to copying. Retry never
auto-pastes or replaces the clipboard, regardless of the setting. Some apps ignore synthetic paste;
“Paste sent” means the shortcut was sent, not that the destination confirmed insertion.
Text appears after you finish recording, not word-by-word while speaking. New recordings are
ignored during transcription; the notch hides when processing finishes. Copy is disabled with
no nonempty transcript; Retry is disabled while recording/processing or when the latest audio
is unavailable. Older recordings are not silently substituted for the latest one.

### Why remap the microphone key?

macOS reserves the microphone key as the Consumer/Voice Command HID usage `0xC000000CF`.
Enable maps it to F13 using Apple's built-in `hidutil` and intercepts F13 (plus ordinary F5)
with a global event tap. Only keyboard devices are targeted; other key mappings are preserved.
macOS 27's per-keyboard mapping tables and older OpenStep output are both supported. If connected
keyboards have different mapping sets, setup refuses rather than flattening their customizations.
If your microphone key already has a different custom mapping, setup refuses rather than overwriting it.

The app remembers your enable choice and reapplies the temporary mapping when reopened.
**Disable** or normal **Quit** removes only its own mapping, leaving concurrent unrelated
changes intact. No privileged helper or persistent LaunchAgent is installed. Force-quitting or
crashing can leave the temporary mapping until you reopen and quit WhistleBar normally or reboot.
If you use standard F-keys, ordinary F5 also works. To launch the app at login, add WhistleBar
under System Settings → General → Login Items.

## History, recovery, and privacy

History & Settings has searchable transcripts, **Copy**, **Retry**, **Reveal audio**, and **Delete**.
Retry uses the selected language and saves the result in history; it never pastes into another app.
Interrupted recordings/transcriptions are marked recoverable on the next launch. WAV files may
be incomplete after a hard crash; recovery is best-effort, not guaranteed.

Files live in `~/Library/Application Support/WhistleBar/`: an atomically written `history.json`
plus 16 kHz mono WAV recordings (~1.9 MB/min). Text remains until you delete it. For recordings
created by this version, recovery audio is kept as follows:

- Successful, nonempty dictations: only the latest **5**, for at most **24 hours** from capture.
- Failed, interrupted, or no-speech recordings: up to **7 days** from capture. Retrying does
  not restart the clock; a successful retry moves into the success policy.
- Existing recordings without retention metadata are **exempt**. The eight recordings already
  on the development Mac are not retrospectively deleted or counted toward the five-record limit.
  History marks these as older recordings kept until you explicitly delete them.

Cleanup runs at launch, around dictation/retry, and every minute while idle. It never removes
audio during recording, transcription, or retry; deadlines may therefore be exceeded until idle
or the next launch. Only WAV audio expires: transcript text and successful status are unchanged.
When audio is gone, **Retry** and **Reveal audio** are disabled with an explanation; **Copy**
still works. **Delete** removes transcript and any remaining audio, with confirmation.
The directory is user-only, but files are **not separately encrypted**: use FileVault for
at-rest protection. Use **Open folder** to back up or inspect files. An unreadable history
index is not silently discarded or overwritten.

The application contains no networking or analytics. The clipboard is intentionally shared with
the OS: other apps and Apple's Universal Clipboard may access/sync copied text. The destination
app may send pasted text to its own servers. Accessibility and Input Monitoring are broad macOS
permissions; this app only processes the two shortcut keycodes and reads focus when dictating.

## Languages and limits

Auto-detect or choose English, Spanish, French, German, Italian, Dutch, or Polish.
**The stock Whistle model does not list Catalan support.** This app does not add languages,
LLM rewriting, formatting commands, filler-word cleanup, or Wispr Flow's other smart editing features.
Long recordings use Whistle's built-in 30-second windowing; final transcription reads the
recording into memory, so memory use grows with its length. The app captures the default system
microphone. Sleep/session lock stops recording; keyboard-monitor interruptions stop and save too.

## Verification

```sh
bash scripts/test.sh
```

The eight cross-platform Swift Testing tests cover hold/double-tap timing, repeat handling,
timeout/cancellation, history round-tripping, interrupted-session recovery, audio deletion,
corrupt-index preservation, and deterministic retention boundaries (24 hours, 7 days, latest
five, silence, legacy exemption, active sessions, and preservation of text/index).
On macOS the package also builds the native executable; fetch the runtime first with
`bash scripts/fetch-runtime.sh`. Linux builds only the portable core, not AppKit/AVFoundation.
Swift 6 or newer is required for the tests. The test script explicitly loads the bundled testing
macro plugin when needed by Command Line Tools 27; it does not require XCTest or full Xcode.

### Actual local validation — October 29, 2026

On an Apple Silicon MacBook Pro running macOS 27.2 with Swift 6.4 Command Line Tools:

- `bash scripts/build-app.sh`: passed all eight tests, release build, ad-hoc signing, strict
  signature verification, and ZIP packaging. All pinned runtime/model checksums matched.
- Native Swift/AVFoundation/C++ validation with the real bundled model: the public whisper.cpp
  JFK human-speech sample transcribed correctly; silence produced empty text; four repeats
  (43.96 seconds) transcribed across the 30-second window boundary.
- The actual controller, using disposable history: interrupted sessions became retryable;
  missing audio produced a saved failure; replacing the fixture and retrying recovered the
  transcript, which survived a disk reload. Clipboard copy matched the recovered text, and
  the pre-test clipboard contents were restored.
- The real macOS 27 keyboard table parsed correctly. Fixture checks also covered old hexadecimal
  OpenStep values, identical per-device mappings, and safe rejection of differing device mappings.
  No keyboard mappings were changed during these checks; before/after output matched exactly.
- The built-in screen reports a 38-point top safe area and a camera gap at x=790…1010 on an
  1800×1169-point desktop. Native render checks cover both sides × light/dark appearance ×
  Ready/Listening/Processing (12 states), including actual panel bounds, transparency,
  click-through/nonactivation, unchanged frontmost app, and persistence of the side preference.
  Screenshots/recording use controlled menu-band contrast backdrops and a simulated camera
  cutout because macOS desktop capture does not include the physical cutout. They are native
  renders, not generated design references; system appearance settings were not changed.
- Disposable history UI checks verified readable retention/exemption descriptions and external
  Accessibility inspection confirmed disabled Retry/Reveal for expired audio versus enabled
  controls for legacy audio. Startup cleanup preserved successful text/status after WAV expiry;
  attempting Retry without audio did not start inference or alter the successful entry.
- The installed app's actual Left/Right segmented control was exercised through Accessibility:
  Right remained selected after quit/relaunch, then Left was restored. After installation and
  startup cleanup, the eight existing WAV SHA-256 hashes and history index bytes were unchanged.
- After removing idle notch status, six updated native states (Idle/Listening/Processing ×
  light/dark) confirmed the panel is absent when idle, including after result notices. The
  menu-bar item uses the shared glyph in all states, and its host leaves button hit testing intact.
  The real installed menu was opened and captured with all five actions; idle Stop was disabled.
  Finder's resolved installed icon was captured and confirmed to be the five-bar mark.
- Disposable native validation of the actual paste sender exercised real ⌘V into a separate
  AppKit input app: Current input pasted exactly into a different focused field; Starting input
  blocked the changed field and pasted into the original; Clipboard only sent nothing; a secure
  field was rejected; sleep/lock cancellation blocked paste. Temporary source copies exposed
  private state solely for these checks; production permissions/focus checks were unchanged.
- The native menu action handlers copied the latest nonempty transcript despite a newer empty
  failure, disabled retry without latest audio/during capture/inference, and retried a disposable
  silence WAV with the real Whistle model. Retry changed only the fixture history, not input or
  clipboard. All three setting descriptions were rendered and inspected. The pre-test clipboard
  and focus were restored, and no user recording was modified.
- The notch master switch was checked against the actual native panel: turning it off instantly
  hid recording bars and the processing spinner without changing microphone-enabled/active
  state; subsequent status updates stayed hidden, and a controller reload restored Off. Both
  switch states and the matching bundled header icon were rendered/inspected in light and dark.
  The real installed checkbox and disabled/enabled side controls were exercised through AX;
  Off survived a normal quit/relaunch and the prior Off choice was restored after testing.
  The app was left Ready with its key mapping active. All nine recordings present at this
  later update, plus history index bytes, remained unchanged. Clipboard was not touched.

After the user granted permissions, the installed `/Applications/WhistleBar.app` passed live checks:

- Synthetic F5 down/up events through the real global event tap started recording immediately,
  then stopped on release. Public JFK speech played through the Mac's audio output was captured
  by the actual default microphone, transcribed, copied, and pasted exactly into a disposable
  native app's focused text view. The neighboring input remained empty, and the overlay did not
  steal focus. This used real acoustic capture, not a file injected into the recorder.
- F13 double-tap remained recording after both releases and beyond the timeout. The next press
  stopped it and pasted the live microphone transcript correctly.
- A quick single F5 tap stopped after its double-tap window, saving 0.437 seconds of audio.
- Moving focus between two inputs in the same destination app prevented automatic paste under
  the earlier guarded behavior (now the optional Starting input only mode), while the transcript
  remained on the clipboard. Current input intentionally changes this behavior as described above.
- Normal quit removed the Voice Command→F13 mapping; relaunch automatically restored it. The
  mapping sets before quit and after relaunch matched. The Mac had no unrelated mappings, so
  preservation of nonempty unrelated mapping sets was covered by fixtures, not a live mutation.
- Screenshots and an inspected screen recording captured actual paste and changed-focus states.
  Only the four disposable test recordings were deleted; all eight pre-existing history entries
  were preserved exactly. The prior clipboard contents were restored.

The final build is installed at `/Applications/WhistleBar.app` and strictly signature-verified.
New ad-hoc signatures invalidated Accessibility trust during updates, requiring a user regrant
in System Settings → Privacy & Security → Accessibility, then **Enable microphone key**.
The final readback now reports **Ready** with **Disable microphone key** available and the
expected Voice Command→F13 mapping installed: permission is active again, not blocked.
Earlier complete microphone/gesture checks were before the final rebuild; the newer paste/menu
checks used native disposable fixtures as detailed above. No permission bypass was attempted.

Still unverified: an independently observed physical hardware microphone-key press (shortcut tests
used synthetic F5/F13 events), permission revocation, browser-specific paste behavior, and
full-screen/external-display behavior.

**Before replacing your existing dictation app**, verify on your Mac: grant/revoke permissions;
hold, double-tap, and single-tap in TextEdit and a browser input; change focus before transcription
finishes (must paste into the new input in Current input mode, copy only in Starting input only
mode); speak >30 seconds; test silence, retry, and copy from history; quit
and verify the key returns to Apple; check the notch panel with full-screen apps and an external
display. A passing build and file-based model checks do not replace these live interaction checks.

## Upstream

- Engine: Cactus-Compute/needle3, revision `d6c7d6a2e9655505e0f8e23339356dd1705900eb`.
- Model: Cactus-Compute/whistle, revision `741118687e1f008f06d1351a402a731274789790`.
- Engine and model: Apache-2.0. Their license is bundled in the app's Resources folder.
- `Vendor/` is downloaded, ignored by Git, and checksum-verified on every build.
