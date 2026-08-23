# Sharpi Transcribe

A private macOS menu-bar dictation app and resident local speech-to-text service. This is a
standalone project: it does not run inside, import, deploy, or restart the Sharpi Host.

The engine keeps Cohere Transcribe 03-2026 Q4 resident on Apple Metal and exposes one
OpenAI-compatible endpoint on loopback. The native companion reports actual model health, records
while a global hotkey is held, and pastes into the field that was focused when recording began. If
focus changes or Accessibility access is unavailable, it copies the transcript instead.

## Requirements

- Apple silicon Mac running macOS 14 or newer
- Node.js 22.19 or newer
- `cohere-transcribe-03-2026-Q4_K_M.gguf`

## Setup

```sh
npm ci
cp .env.example .env
chmod 600 .env
```

Set the absolute model path in `.env`:

```sh
TRANSCRIBE_MODEL="$HOME/.local/share/sharpi-transcribe/models/cohere-transcribe-03-2026-Q4_K_M.gguf"
# TRANSCRIPTION_PORT=3212
# AFCONVERT_PATH=/usr/bin/afconvert
# TRANSCRIBE_SIGNING_IDENTITY=Apple Development certificate hash or name
```

The installer requires an owner-only, mode-0600, non-symlink `.env`. Builds are ad-hoc signed by
default. Configure an Apple Development identity before granting permissions if you plan to
rebuild frequently, so macOS can preserve Microphone and Accessibility grants.

## Build and install

```sh
npm run check
npm run build
npm run install:mac
```

Installation builds and signs `dist/Sharpi Transcribe.app`, copies it to `~/Applications`, installs
a launch-safe production runtime under `~/.local/share/sharpi-transcribe/runtime`, and starts two
per-user LaunchAgents. The source repository stays in `~/Documents`; launchd cannot execute code
directly from that macOS-protected folder.

- `com.sharpi.transcribe.service` keeps the model resident even when the menu app quits.
- `com.sharpi.transcribe.menu` starts the visible accessory app at login.

The first launch opens Settings but does not trigger permission prompts. Use the buttons there to
request **Microphone** and **Accessibility** access. The default push-to-talk shortcut is
**Option-Space**.

```sh
npm run status
npm run uninstall:mac
```

Logs are stored in `~/.local/state/sharpi-transcribe/`.

## HTTP API

The service binds only `127.0.0.1` and accepts:

```text
GET  /healthz
POST /v1/audio/transcriptions
```

The transcription route accepts OpenAI-style multipart uploads with `file`, optional `language`,
and `response_format` set to `json`, `text`, or `verbose_json`. AAC/M4A, CAF, FLAC, MP3/MP4,
Ogg/Opus, WAV, and WebM are supported. Recordings are limited to ten minutes and requests are
serialized through the resident model.

Example:

```sh
curl -F response_format=json -F file=@recording.m4a \
  http://127.0.0.1:3212/v1/audio/transcriptions
```

All unrelated routes return 404. The service has no bearer token; the signed-in macOS user is the
local trust boundary.

## Tailnet access

To make only this API available through Tailscale, use Serve—not Funnel—and grant the intended
client access to the selected HTTPS port:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:3212
```

Hermes can use the resulting URL ending in `/v1` as its OpenAI STT base URL. If its client insists
on an API key, use the literal non-secret value `not-needed`; this service ignores Authorization.

## Development

```sh
npm run serve
scripts/build-app --debug
```

DEBUG builds support deterministic UI capture with `TRANSCRIBE_FIXTURE`, `TRANSCRIBE_SHOW`, and
`TRANSCRIBE_CAPTURE_DIR`. Audio bytes and transcript text are never written to service logs, and
temporary recordings are removed after each dictation.
