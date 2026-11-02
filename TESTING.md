# Testing

## Automated (runs on Command Line Tools)

```bash
swift run DictateCoreTests
```

These tests cover the logic that does not need a microphone, a network connection or permissions:

- Multipart request: `model`, `prompt`, `keywords[]`, `languages[]`, `response_format`; keyword sanitizing (no `<`, `>`, CR, LF; dedupe); vocabulary folded into the prompt for models without `keywords`; singular `language` for older models.
- Response decoding: `text`, `languages`, both `usage` shapes (tokens, duration).
- Error mapping: 400 with `param`, 401, 429 rate limit vs quota/billing, 5xx, offline, timeout.
- Retry policy: backoff, `Retry-After`, no automatic retry for timeouts or quota errors.
- Clean mode filler removal (keeps "umbrella", keeps `github.com`, keeps final punctuation), no trailing newline ever, single-line joining for terminals, Polished-mode guard.
- Responses API body (`store: false`, transcript wrapped as data) and output parsing.
- State machine: no overlapping recordings, no duplicate transcription, cancel, retry, settle.
- Monthly usage rollover and cost estimates.
- Shortcut validation, Cocoa→Carbon modifiers, macOS shortcut conflict detection.

Also checked while building (not part of the test runner):

- The recorder's convert-and-encode path, fed synthetic 48 kHz stereo speech in 2048-frame chunks, produces a valid mono 24 kHz AAC `.m4a` at about 61 kbps.
- Clipboard snapshot and restore round-trips several items and types (text, PNG data, file URL) on a private pasteboard.
- The bundled app launches, stays running, and quits cleanly with no crash report.

## Manual checklist

These need your microphone, the Accessibility grant and a real API key, so they were **not** run while building. Each one: put the cursor in the field, tap Right ⌘ (or hold Right ⌥), say a sentence that includes "Django, Celery and Redis", then release.

| # | Target | Expected | Pass |
|---|---|---|---|
| 1 | Chrome: any `<input>` / `<textarea>` (for example a GitHub comment box) | Text appears at the cursor. The clipboard still holds what you copied before. | ☐ |
| 2 | Gmail compose body in Chrome | Text inserted at the cursor. No send. | ☐ |
| 3 | Cursor editor (a code file) | Inserted at the caret. Undo (⌘Z) removes it in one step. | ☐ |
| 4 | Claude Code input (in Terminal / iTerm / VS Code terminal) | Inserted on one line. Nothing is submitted; you still press Return yourself. | ☐ |
| 5 | VS Code editor | Inserted at the caret. | ☐ |
| 6 | Apple Notes | Inserted (via Accessibility, so the clipboard is never touched). | ☐ |
| 7 | Terminal.app shell prompt | Inserted as one line. The command is **not** executed. | ☐ |
| 8 | 20-second dictation into any of the above | Text appears without touching another window. | ☐ |

Behaviour checks:

| # | Scenario | Expected | Pass |
|---|---|---|---|
| 9 | Tap Right ⌥ ten times quickly. Then tap Right ⌘ several times quickly. | Right ⌥ taps are ignored. Each Right ⌘ tap starts or stops a recording, never overlapping. | ☐ |
| 9b | Use ⌘C / ⌘V / ⌘-click with Right ⌘ | No recording starts. | ☐ |
| 9c | Set both keys to Right ⌥. Tap it, speak, tap it again. Then hold it, speak, release. | Both transcribe. | ☐ |
| 10 | Esc while recording | Recording discarded, nothing sent. | ☐ |
| 11 | Esc while transcribing | Request cancelled, nothing inserted. | ☐ |
| 12 | HUD ✕ / ■ buttons | Work, and focus stays in your app. | ☐ |
| 13 | Copy an image, dictate into Chrome, then paste | The image comes back (clipboard restored). | ☐ |
| 14 | Select a word, dictate (default settings) | The selection is kept and text goes after it. | ☐ |
| 15 | Start recording, switch app with ⌘Tab, release | Text goes into the original app ("Return to the app I was in" on). | ☐ |
| 16 | Hold Right ⌥, click another window, release | Recording stops on release. | ☐ |
| 17 | Remove the API key, dictate | Clear error before recording starts. | ☐ |
| 18 | Wi-Fi off, dictate | "No internet connection". Recording kept; **Retry** works once Wi-Fi is back, without re-recording. | ☐ |
| 19 | Invalid key | "OpenAI rejected the API key." Recording kept. | ☐ |
| 20 | Quit during a failed state, relaunch | Menu offers Retry / Discard for the kept recording. | ☐ |
| 21 | Turn off Accessibility for Dictate, dictate | Text is copied, and you see "Copied – press ⌘V". | ☐ |
| 22 | Password field (any login form) | Nothing inserted; "Not inserted" shown. | ☐ |
| 23 | Unplug a USB or Bluetooth mic mid-recording | Recording continues on the built-in mic, or stops and transcribes what was captured. | ☐ |
| 24 | Tap Right ⌘, speak for 20 s hands-free, tap Right ⌘ again | Text is inserted. | ☐ |
| 24b | While typing, use Right ⌥ in shortcuts (⌥←, ⌥-letter) | No recording is kept; typing is unaffected. | ☐ |
| 25 | Turn on the key combination (⌥Space); change the hold key to Right ⌃ | ⌥Space toggles recording. Right ⌃ holds. With the combination off, ⌥Space types normally. | ☐ |
| 26 | Clean and Polished modes | Fillers removed. Polished shows the extra-cost note, and Usage shows a Polished-mode cost. | ☐ |
| 27 | Set max length to 1 min, talk for 70 s | Stops at 1:00 and transcribes. | ☐ |
