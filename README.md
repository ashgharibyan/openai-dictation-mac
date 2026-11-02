# Dictate: open-source voice dictation for macOS, powered by OpenAI

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange)
![Model: gpt-transcribe](https://img.shields.io/badge/OpenAI-gpt--transcribe-black)

**Dictate** is a free, open-source **speech-to-text app for Mac**. Press one key, talk, and your words are typed wherever your cursor is: Chrome, Gmail, Slack, VS Code, Cursor, Claude Code, Terminal, Notes and more. It uses OpenAI's newest transcription model, **`gpt-transcribe`**, with your own API key.

It's a lightweight, native alternative to subscription dictation apps such as Wispr Flow and Superwhisper. You pay OpenAI only for what you use (about **$0.0045 per minute** of speech). There's no account, no subscription, no server and no telemetry.

> Not affiliated with or endorsed by OpenAI. "OpenAI" and "ChatGPT" are trademarks of OpenAI.

## Features

- **Works in any app.** It inserts text at the cursor in browsers, Electron apps, IDEs and terminals.
- **Two shortcuts, no typing interference.** **Tap Right ⌘** to start and tap again to stop, or **hold Right ⌥** while you talk. A modifier key on its own types nothing, so the shortcuts never leak characters into your text.
- **High accuracy.** It uses `gpt-transcribe` with OpenAI's documented `prompt`, `keywords[]` and `languages[]` hints. Add your own vocabulary (names, products, code terms) to improve spelling.
- **Your words, not an AI rewrite.** The default output is exactly what you said. Optional **Clean** mode removes "um" and "uh" locally at no cost. Optional **Polished** mode is a separate, clearly priced text-model step.
- **Your clipboard is safe.** When the app pastes, your previous clipboard is restored afterwards, including images and files.
- **Terminal-safe.** It never presses Return, so a dictated command is never executed.
- **Never loses a recording.** If transcription fails (offline, rate limit, billing), the recording is kept so you can **Retry** without speaking again.
- **Private by default.** The API key is stored in the macOS Keychain. Audio is deleted after use. There's no history unless you enable it, and audio goes only to `api.openai.com`.
- **Tiny and native.** Swift, SwiftUI and AppKit, with no third-party dependencies. The app is about 1.6 MB.
- **Usage tracking.** See minutes, dictation count, average latency and estimated cost per month.

## Quick start

**Requirements:**
- macOS 14 (Sonoma) or later.
- Xcode Command Line Tools: run `xcode-select --install`. Full Xcode is not required.
- An [OpenAI API key](https://platform.openai.com/api-keys) with billing enabled.

```bash
git clone https://github.com/ashgharibyan/openai-dictation-mac.git
```

```bash
cd openai-dictation-mac && ./scripts/install.sh
```

`install.sh` runs the tests, builds `Dictate.app`, copies it to `/Applications` and launches it. A microphone icon appears in your menu bar.

On first launch, Settings opens:

1. **OpenAI tab:** copy your API key and click **Paste & Save**. It's validated right away.
2. **General tab → Permissions:**
   - **Microphone:** allow it.
   - **Accessibility:** turn on **Dictate** under System Settings → Privacy & Security → Accessibility. This is needed to type into other apps and to see the shortcut keys while you're in other apps.
3. Click into any text field, **tap Right ⌘**, speak, and tap again.

Dictate does not need Input Monitoring or Screen Recording.

### Tip: keep permissions across rebuilds

Builds are signed ad hoc by default, so macOS treats every rebuild as a new app: Accessibility then needs to be removed and re-added. Run this once, then rebuild:

```bash
./scripts/create-signing-cert.sh
```

It creates a local self-signed code-signing certificate and asks for your password to trust it. After this, permissions stay granted across rebuilds.

## Shortcuts

| Action | Default | Configurable to |
|---|---|---|
| Tap to start, tap again to stop | **Right ⌘** | Right ⌥, Right ⌃, fn / 🌐, Off |
| Hold to talk, release to transcribe | **Right ⌥** | Right ⌘, Right ⌃, fn / 🌐, Off |
| Key combination (optional) | Off (⌥Space when enabled) | Any combination with ⌃, ⌥ or ⌘ |
| Cancel | **Esc**, only while recording or transcribing | — |

- **One key for both.** Set the tap and hold keys to the same key. A quick tap then starts hands-free recording, and a longer press records until you let go.
- **No false starts.** A tap only counts when the key is pressed alone and released within 0.4 s, so ⌘C, ⌘V and ⌘-click never start a recording.

## Transcription settings

| Setting | Default | Sent to OpenAI as |
|---|---|---|
| Model | `gpt-transcribe` | `model` |
| Languages | `en` (add more, or auto-detect) | `languages[]` (`language` on older models) |
| Context prompt | Short description of the speaker and topics | `prompt` |
| Vocabulary | OpenAI, ChatGPT, Claude Code, Cursor, GitHub, Python, JavaScript, TypeScript, Swift, API, LLM | `keywords[]` (added to the prompt on older models) |
| Output mode | Verbatim | — (applied locally, or in a separate request for Polished) |

Keywords are hints: they fix spelling when a word is spoken, and they are never forced into the text. Older models (`gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1`) are selectable too; OpenAI is removing them on Feb 26, 2027.

**Output modes:**
- **Verbatim** (default): exactly what the model returned.
- **Clean:** removes filler sounds (um, uh, hmm) and tidies spacing, on your Mac. No extra cost, and your wording is never changed.
- **Polished:** a separate OpenAI text model (`gpt-6-luna` by default, `store: false`) fixes grammar and readability. It costs extra, roughly $0.0001 per dictation, and adds latency. If the output looks altered, or the call fails, Dictate inserts the Clean text instead.

## How text insertion works

- **Native Mac text fields** (Notes, TextEdit, Mail): text is written through the Accessibility API, and Dictate checks that the field actually changed.
- **Browsers, Electron and Chromium apps, terminals:** the text goes on the clipboard, then ⌘V, then your previous clipboard is restored. The clipboard is not restored if something else changed it in the meantime. The temporary entry is marked transient, so clipboard managers ignore it.
- **Never sends Return/Enter.** In terminals, line breaks become spaces.
- **Keeps your selection** by default instead of overwriting it. This is configurable.
- **Password fields are skipped.** If secure input blocks typing, the text is copied and you're told.
- **Doesn't work** in apps that accept neither Accessibility writes nor ⌘V, such as some games, VMs and remote desktops. There, use **Copy Last Transcript** from the menu.

## Reliability

- **One session at a time.** The state machine is Idle → Recording → Transcribing → Inserting → Idle, with cancel and error paths. It prevents overlapping recordings and duplicate (billable) requests.
- **Never sent:** recordings that are too short or silent, which avoids charges and hallucinated text.
- **Automatic retries:** rate limits and 5xx errors, with backoff and `Retry-After`. Timeouts are **not** retried automatically, because OpenAI may already have billed the first attempt.
- **Microphone changes:** if the mic is unplugged mid-recording, recording continues on the next input device. If none is left, Dictate transcribes what it captured.
- **Long recordings:** there's a configurable cap (15 min default, 30 max). Audio is about 0.46 MB per minute, well under the 25 MB upload limit.
- **Kept recordings:** a failed recording survives quitting the app and is deleted after 24 hours or when you discard it.

## Privacy and security

- **API key:** stored in the macOS login Keychain, sent only to `api.openai.com` over HTTPS, and never logged.
- **Audio and history:** audio is deleted after a successful insert. Transcript history and audio history are off by default.
- **No tracking:** no analytics, no telemetry, no third-party services, no server.
- **Logs** (`log stream --predicate 'subsystem == "local.dictate"'`): states and HTTP status codes only.
- **Local files:** `~/Library/Application Support/Dictate/`.

## Cost

Settings → Usage shows minutes, dictations, average transcription time and estimated cost for the current month. Estimates use OpenAI's published price for `gpt-transcribe` ($0.0045 per minute). Your actual bill is at [platform.openai.com/usage](https://platform.openai.com/usage).

For example, 30 minutes of dictation a day comes to about **$4 a month**.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Settings says Accessibility needs granting, but the switch is on | You rebuilt the app. Remove Dictate from the Accessibility list with **−**, add it again, or run `scripts/create-signing-cert.sh` once. |
| Repeated Keychain password prompts | Click **Always Allow**, or re-save the key (**Paste & Save**) so the current build owns it. |
| "OpenAI billing limit: You have no credits remaining" | The organization that owns your API key has no credit. Check the organization and project at platform.openai.com/settings/organization/billing. |
| Right ⌘ / Right ⌥ do nothing in other apps | Grant Accessibility. Dictate re-attaches its key monitor automatically once access is granted. |
| fn key triggers emoji or dictation | Set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**. |

## Building from source

```bash
swift run DictateCoreTests
```

That runs the unit tests. XCTest needs full Xcode, so the tests are a small built-in runner.

```bash
./scripts/build-app.sh
```

That builds and signs `build/Dictate.app`.

```bash
open build/Dictate.app
```

That runs it without installing.

**With full Xcode:**
- Open `Package.swift`.
- Or generate a project with `brew install xcodegen && xcodegen generate`. This spec has not yet been built with Xcode.

**Distributing builds:** apps you build yourself run fine on your Mac. To share a build with others, sign it with an Apple Developer ID and notarize it, otherwise Gatekeeper blocks it on their Mac.

### Project layout

| Area | File |
|---|---|
| State machine | `Sources/DictateCore/DictationStateMachine.swift` |
| Models, prices, supported fields | `Sources/DictateCore/TranscriptionModel.swift` |
| Multipart request, keyword and language sanitizing | `Sources/DictateCore/TranscriptionRequest.swift` |
| Errors and retry policy | `Sources/DictateCore/TranscriptionError.swift` |
| Clean mode, Polished guard | `Sources/DictateCore/TextProcessing.swift` |
| Polished mode (Responses API) | `Sources/DictateCore/PolishRequest.swift` |
| Orchestration | `Sources/Dictate/DictationController.swift` |
| Microphone (AVAudioEngine → mono 24 kHz AAC) | `Sources/Dictate/Audio/AudioRecorder.swift` |
| HTTP client | `Sources/Dictate/Networking/OpenAIClient.swift` |
| Shortcuts | `Sources/Dictate/Input/ModifierKeyMonitor.swift`, `HotkeyManager.swift` |
| Text insertion | `Sources/Dictate/Input/TextInserter.swift`, `ClipboardSnapshot.swift` |
| Menu bar, floating indicator, Settings | `Sources/Dictate/UI/` |

To add a transcription model, add one entry to `TranscriptionModel.all`.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the manual test checklist in [TESTING.md](TESTING.md).

## License

[MIT](LICENSE)

---

*Keywords: macOS dictation app, speech to text Mac, voice typing Mac, OpenAI Whisper Mac app, gpt-transcribe, push to talk dictation, open source Wispr Flow alternative, Superwhisper alternative, menu bar dictation, voice to text for developers, dictation for Claude Code and Cursor.*
