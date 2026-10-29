<p align="center">
  <img src="macos/Chinwag/Assets/ChinwagIcon.png" alt="Chinwag singing bird icon" width="180">
</p>

# Chinwag

Local push-to-talk dictation for macOS, powered by Parakeet Unified streaming on Apple Metal.

## Install

Requires Apple silicon, macOS 14+, and Xcode command-line tools.

```sh
scripts/service install
```

First launch downloads a 0.73 GB model. Grant Microphone and Accessibility access in Settings.

Optional: pass `--sign "Apple Development: Your Name (TEAMID)"` to preserve permissions across rebuilds.

## Use

Hold **Option-Space**, speak, then release to paste. Parakeet transcribes while you speak; Settings can switch dictation and batch to the Cohere fallback (1.56 GB download). If focus changed, the text stays on the clipboard. Audio stays on your Mac.

```sh
scripts/service status
scripts/service uninstall
```

Dictation and API clients share one warm model and queue on it; no session is rejected for another being active. Quitting Chinwag stops the API and unloads the model. Installing replaces the old separate service LaunchAgent if present.

## API

OpenAI-compatible transcription for native apps and CLI clients.

```text
Base URL  http://127.0.0.1:3212/v1
POST      /audio/transcriptions
Model     whisper-1
```

Live streaming, also for browser clients:

```text
GET  /v1/live/models          {"data":[{"id":"parakeet-unified-en-0.6b","state":"ready","default":true}]}
WS   /v1/live?model=<id>      send binary 16 kHz mono PCM16 LE frames, then {"type":"end"}
                              receive {"type":"partial","text":…}, one {"type":"final","text":…} then close,
                              or {"type":"error","message":…}
```

Finals drop fillers (um, uh, er, ah, hmm) and immediate repeats ("the the"), keeping the model's punctuation.

No API key required. Use `not-needed` if your client requires one. Loopback only, no HTTP authentication. Keep it private.

## Check

```sh
scripts/check
```

With the model installed, `python3 tests/integration/run.py` tests real Metal transcription, concurrent live streams, and warm API latency. `python3 tests/integration/live.py <ws-url> <wav>` measures real-time end-to-final latency.
