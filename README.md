# Chinwag

Chinwag is local push-to-talk dictation for macOS.

Hold **Option-Space**, speak, then release. Cohere Transcribe runs on Apple Metal and pastes the text where you started.

## Install

You need Apple silicon, macOS 14 or newer, [mise](https://mise.jdx.dev/), and Xcode command-line tools.

```sh
mise install
scripts/check
scripts/service install
```

The first check downloads a pinned `transcribe.cpp` release. It uses no npm, Cargo, or CMake.

On first launch, Chinwag downloads the 1.56 GB model from the Apache-2.0 [Cohere GGUF release](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf). It stores the model in `~/.local/share/chinwag/models`. Progress appears in Settings.

Grant **Microphone** and **Accessibility** access in Settings.

## Use

1. Focus a text field.
2. Hold **Option-Space** and speak.
3. Release **Option-Space**.

Chinwag pastes into the original field. If focus changed, it leaves the text on the clipboard.

## Service

A Go service keeps Cohere loaded in memory. Quitting the menu app does not unload it.

```sh
scripts/service status
scripts/service uninstall
```

The app is in `~/Applications`. Runtime files are in `~/.local/share/chinwag/runtime`. Logs are in `~/.local/state/chinwag`.

## Hermes

Chinwag serves OpenAI-compatible transcription on loopback:

```text
GET  http://127.0.0.1:3212/healthz
POST http://127.0.0.1:3212/v1/audio/transcriptions
```

For remote Hermes access, use Tailscale Serve:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:3212
```

Set Hermes's STT base URL to the Serve URL ending in `/v1`. Use `not-needed` as the API key. Grant access only to the intended tailnet client. Do not use Funnel.

## Limits

Audio stays on the Mac. Temporary recordings are removed. Audio and transcript text are not logged. Recordings can be up to 25 MiB and ten minutes.
