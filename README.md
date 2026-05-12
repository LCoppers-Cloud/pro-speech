# pro-speech

iOS earpiece-prompter. The app transcribes a public speaker live (on-device, iOS 26
`SpeechAnalyzer`), tracks their speaking pace, and streams a few words of suggested
continuation from Claude Haiku 4.5 — shown on screen with a karaoke-style highlight
and whispered into AirPods so the speaker hears what to say next, just in time.

## How it works

```
mic ──► SpeechTranscriber ──► PacingBrain ──► ClaudeStream ──► PromptBuffer
                                  │                                  │
                                  └──► word highlight ◄──── on-screen view
                                                            TTS to AirPods
```

The **pacing brain** is the core. It tracks the speaker's syllables per second
with a dual-timescale EWMA, fuzzy-aligns what they are actually saying against the
buffered prompt (so paraphrase doesn't break the highlight), and fires the next
Claude request *speculatively* — when the words still buffered fall below
`N_min = ⌈WPM/60 · lookahead · 1.19⌉` — so the next chunk is already streaming
back by the time the speaker needs it.

See `Sources/ProSpeechBrain/BufferPolicy.swift` for the equations.

## Project layout

```
pro-speech/
├── Package.swift              # Brain modules as a Swift package (testable from CLI)
├── project.yml                # XcodeGen spec for the iOS app
├── Sources/
│   ├── ProSpeechBrain/        # Pure Swift, no iOS deps — runs in `swift test`
│   └── ProSpeech/             # iOS app target, uses ProSpeechBrain
├── Tests/
│   └── ProSpeechBrainTests/
└── Resources/
    └── Info.plist
```

## Build

Requires macOS 26, Xcode 26, iOS 26 SDK.

```bash
brew install xcodegen        # one-time
xcodegen generate
open ProSpeech.xcodeproj
```

The brain logic can also be tested without Xcode:

```bash
swift test
```

## Configuration

On first launch, open Settings and paste your Anthropic API key. It is stored in
the iOS Keychain. The app uses `claude-haiku-4-5` for speed and prompt-caches
your notes + persona for the duration of the session.

## Status

Early scaffold. The brain layer and Claude client are implemented and unit-tested;
the audio + UI layer is wired but needs device-testing on iOS 26 hardware.
