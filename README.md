# Chinwag

Chinwag is local push-to-talk dictation for macOS. Hold **Option-Space**, speak, then release. Chinwag turns the recording into punctuated text and pastes it into the field where you started.

Cohere Transcribe 03-2026 Q4 runs on Apple Metal. A resident Go service keeps the model loaded, so each dictation starts quickly. If focus changes before transcription finishes, Chinwag leaves the text on the clipboard instead of pasting into the wrong app.

## Install

### 1. Check the requirements

- An Apple silicon Mac with macOS 14 or newer.
- [mise](https://mise.jdx.dev/) and the Xcode command-line tools.
- npm for fetching the pinned native transcription libraries.
- `cohere-transcribe-03-2026-Q4_K_M.gguf` from the [Cohere GGUF release](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf).

### 2. Prepare the Project

```sh
mise install
npm ci
cp .env.example .env
chmod 600 .env
```

Keep the model outside the Project. Set its absolute path in `.env`:

```sh
TRANSCRIBE_MODEL="$HOME/.local/share/chinwag/models/cohere-transcribe-03-2026-Q4_K_M.gguf"
# TRANSCRIPTION_PORT=3212
# AFCONVERT_PATH=/usr/bin/afconvert
# TRANSCRIBE_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
```

### 3. Check and install Chinwag

```sh
npm run check
npm run install:mac
```

The installer adds `Chinwag.app` to `~/Applications`. It puts the resident service and native Metal libraries in `~/.local/share/chinwag/runtime` and starts both at login.

### 4. Grant access

The first launch opens Settings. Use the buttons there to grant **Microphone** and **Accessibility** access. Chinwag asks only after you choose each action.

Builds use ad-hoc signing by default. If you rebuild often, set `TRANSCRIBE_SIGNING_IDENTITY` before granting access. A stable Apple Development signature helps macOS preserve these grants.

### 5. Dictate

1. Focus the field where you want the text.
2. Hold **Option-Space**.
3. Speak.
4. Release **Option-Space**.

Chinwag records through the menu app, transcribes through the resident service, and restores the clipboard after a successful paste.

## How it works

The menu app handles the shortcut, recording, permissions, and paste. The Go service keeps Cohere loaded and calls the pinned `transcribe.cpp` Metal libraries directly. Requests run one at a time through the model.

npm is used only during setup and builds. The installed service runs as a Go executable with its native libraries. Quitting the menu app leaves the model resident.

Check the installed services:

```sh
npm run status
```

Remove the app, runtime, and LaunchAgents:

```sh
npm run uninstall:mac
```

Logs are in `~/.local/state/chinwag/`.

## HTTP API

The service listens on `127.0.0.1:3212`:

```text
GET  /healthz
POST /v1/audio/transcriptions
```

The transcription route uses OpenAI-style multipart uploads. It accepts `file`, optional `language`, and `response_format` values of `json`, `text`, or `verbose_json`.

```sh
curl -F response_format=json -F file=@recording.m4a \
  http://127.0.0.1:3212/v1/audio/transcriptions
```

Supported audio includes AAC/M4A, CAF, FLAC, MP3/MP4, Ogg/Opus, WAV, and WebM. An upload can be up to 25 MiB and ten minutes.

## Hermes over Tailscale

Keep Chinwag on loopback. Use Tailscale Serve for tailnet access:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:3212
```

Grant access only to the intended tailnet client. Use Serve rather than Funnel.

Set Hermes's OpenAI STT base URL to the Serve URL ending in `/v1`. If Hermes requires an API key, use the non-secret value `not-needed`.

## Privacy and safety

- Audio is processed on the Mac with the preinstalled model.
- Temporary recordings are removed after each dictation.
- Audio and transcript text stay out of service logs.
- The local API trusts the signed-in macOS user and has no bearer token.

## Develop

```sh
npm run build
npm run serve
scripts/build-app --debug
```
