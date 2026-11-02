# Contributing

Thanks for helping make Dictate better.

## Setup

```bash
xcode-select --install
```

Command Line Tools are enough; full Xcode is optional.

```bash
swift run DictateCoreTests
```

```bash
./scripts/build-app.sh && open build/Dictate.app
```

## Guidelines

- **Keep it light.** No third-party dependencies, no server, no telemetry.
- **Pure logic goes in `Sources/DictateCore`** (no AppKit), with a test in `Sources/DictateCoreTests/main.swift`.
- **Only use documented OpenAI API fields.** Link the documentation in your pull request when you add or change a request field.
- **Never log API keys, audio or transcript text.**
- **For changes to recording, shortcuts or text insertion,** run the relevant rows of the manual checklist in [TESTING.md](TESTING.md) and say which apps you tested.

## Reporting bugs

Please include:
- Your macOS version.
- The app you were dictating into.
- Your shortcut settings.
- What you expected, and what happened.
- Relevant log lines from: `log stream --predicate 'subsystem == "local.dictate"'`. These never contain your key or your words.

## Security

Please report security issues privately via GitHub's **Report a vulnerability** button (Security tab), not as public issues.
