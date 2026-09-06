<p align="center">
  <img src="macos/Chinwag/Assets/ChinwagIcon.png" alt="Chinwag singing bird icon" width="180">
</p>

# Chinwag

Local push-to-talk dictation for macOS, powered by Cohere Transcribe on Apple Metal.

## Install

Requires Apple silicon, macOS 14+, [mise](https://mise.jdx.dev/), and Xcode command-line tools.

```sh
mise install
scripts/service install
```

First launch downloads a 1.56 GB model. Grant Microphone and Accessibility access in Settings.

Optional: pass `--sign "Apple Development: Your Name (TEAMID)"` to preserve permissions across rebuilds.

## Use

Hold **Option-Space**, speak, then release to paste. If focus changed, the text stays on the clipboard. Audio stays on your Mac.

```sh
scripts/service status
scripts/service uninstall
```

The model stays loaded when you quit the menu app.

## API

OpenAI-compatible transcription for native apps and CLI clients.

```text
Base URL  http://127.0.0.1:3212/v1
POST      /audio/transcriptions
Model     whisper-1
```

No API key required. Use `not-needed` if your client requires one. Loopback only, no HTTP authentication. Keep it private.

## Check

```sh
scripts/check
```
