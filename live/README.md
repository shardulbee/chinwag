# Live transcription

Separate loopback sidecar: no microphone, hotkey, app installation, or batch API changes. Requires `uv`, Python 3.12, Apple silicon, and the existing Chinwag app running for `chinwag-chunked`.

```sh
scripts/live setup
scripts/live fetch-models # ~3 GB; skips installed files
scripts/live run          # foreground; keeps weights loaded
# Or scripts/live install for a login LaunchAgent (scripts/live stop to unload).
scripts/live check
```

The LaunchAgent runs an installed snapshot under `~/.local/share/chinwag/live`, outside macOS's protected Documents directory. Native weights are hardlinked; official Moonshine files use APFS clones, avoiding a second full model copy. Run `scripts/live install` again after source changes. Logs: `~/.local/state/chinwag/live.log`.

`GET http://127.0.0.1:3213/v1/live/models` returns `data` with `id`, `state`, `busy`, `backend_type`, and an `error` for unavailable models. Only race entries with `state: "ready"`. Each model admits one active stream; different models can run concurrently. Missing model files don't prevent other models starting. Weights load at startup, not on each connection.

## Wire protocol

Connect `ws://127.0.0.1:3213/v1/live?model=<id>`. Send binary 16 kHz mono signed PCM16 little-endian (no WAV header), normally 3,200 bytes every 100 ms. Send exactly `{"type":"end"}` to flush. Maximum duration 120 seconds, maximum frame 64,000 bytes, idle timeout 15 seconds. The server emits UTF-8 JSON:

```json
{"type":"partial","text":"Whole current hypothesis, not a delta","model":"moonshine-streaming-tiny"}
{"type":"final","text":"Whole final transcript.","model":"moonshine-streaming-tiny"}
{"type":"error","error":{"code":"model_busy","message":"..."},"model":"moonshine-streaming-tiny"}
```

Replace displayed text on each partial; any part may change. Successful end produces exactly one final, even if empty, then closes. Errors are terminal and do not produce a final. Disconnect abandons the stream and releases its state. Reconnecting starts a fresh utterance. Model-busy errors should be retried after the previous stream closes.

Available IDs:

- `nemotron-speech-streaming-en-0.6b`: transcribe.cpp Q8_0, English, cache-aware streaming, default 1.04s lookahead.
- `nemotron-3.5-asr-streaming-0.6b`: transcribe.cpp Q8_0, English locale selected, cache-aware streaming, default 1.04s lookahead.
- `parakeet-unified-en-0.6b`: transcribe.cpp Q8_0, English, buffered streaming, default 2.08s chunk+lookahead.
- `moonshine-streaming-tiny`, `moonshine-streaming-small`: transcribe.cpp Q8_0, English, incremental encoder and revisable decoder.
- `moonshine-streaming-medium`: downloaded and tested, but discovery reports **unavailable**. On the 24.88s fixture, native 0.2.1 loops “12-inch” in a partial at 4.9s and sets its truncation flag. Later hypotheses recover to correct text, but the flag stays set through finalize. The sidecar honors that signal rather than silently declaring a potentially truncated final. This is a reproduced native-library limitation, not an untested model.
- `moonshine-voice-medium`: official `moonshine-voice==0.1.5` ONNX runtime, quantized English medium streaming model (269 MB). Independent streaming state per connection, 500ms update floor, whole hypotheses assembled from the runtime's line IDs. Works on the full test clip, but repeated two words at voice-activity boundaries (2.9% WER).
- `chinwag-chunked`: existing warm Cohere `/v1/audio/transcriptions` on port 3212. RMS pause detection over 20ms windows, cutting after 200ms quiet and at least 1s per segment, with an 8s hard cut for uninterrupted speech. Pieces transcribe serially in the background while capture continues; end only submits the tail and waits for outstanding pieces. Pure silence is skipped. This is chunked batch inference, **not** native streaming; hard cuts can lose or repeat boundary words. It shares the app's queue and can add contention with dictation/batch clients.

The server sends raw current native hypotheses, not transcribe.cpp's append-only committed prefix, because the committed prefix can disagree with a revised final.

## Tailnet

Configured on turbogadget: `tailscale serve --bg --https=8445 http://127.0.0.1:3213`.

- Discovery: `https://turbogadget.li-werner.ts.net:8445/v1/live/models`
- Streaming: `wss://turbogadget.li-werner.ts.net:8445/v1/live?model=<id>`

8444 continues forwarding the existing batch API to 3212. HTTPS discovery allows cross-origin browser requests. No application authentication; Serve is tailnet-only, **not Funnel**. Access depends on tailnet policy. [ACL PR #24](https://github.com/shardulbee/tailscale-policy/pull/24) was open/unmerged during setup; host HTTPS tests do not prove access from `tag:choux-voice-lab`. No ACL changes were made here.

## Benchmark

```sh
say -v Samantha -r 170 -f tests/live/reference.txt -o /tmp/chinwag-live.wav --data-format=LEI16@16000
runtime/live-venv/bin/python live/benchmark.py /tmp/chinwag-live.wav \
  --reference tests/live/reference.txt --output /tmp/chinwag-live-results.json
```

Feeds the 24.88s English WAV in real time with concurrent send/receive, one model at a time, after a 1s silence warmup. First-partial latency starts at the first audio send. End-to-final starts at the explicit end send, including any processing backlog; it is not just finalizer compute time. Batch baseline uploads the full WAV after capture ends. WER lowercases and ignores punctuation; this one clean synthetic clip is a smoke test, not a general quality ranking. Model loading is excluded. See [measured results](benchmark-results.json).

## Backend investigation and remaining work

- **Parakeet MLX** (`parakeet-mlx==0.5.3`): `from_pretrained(...).transcribe_stream(context_size=(256,256))`, `add_audio(mx.array(...))`, `result.text`; context manager restores attention configuration. `mlx-community/parakeet-tdt-0.6b-v3` weights are 2.51 GB. This is a separate streaming implementation; transcribe.cpp's older TDT/CTC 110M and ordinary RNN-T variants are offline-only. Only Unified and Nemotron expose its streaming API.
- **Kyutai STT 1B en/fr** (`moshi_mlx==0.3.0`): `kyutai/stt-1b-en_fr-mlx`, 1.98 GB LM + 385 MB Mimi. Source `moshi_mlx.run_inference` supports the STT config; `local.py` is hard-coded for Moshi chat and is not the right adapter. Requires continuous 16→24 kHz resampling, Mimi `encode_step` in 1,920-sample frames, `LmGen.step`, and delay padding on end. Keep the LM warm and reset Mimi/generation state per connection. Needs its own environment: its `huggingface-hub<0.29` conflicts with Parakeet's `>=0.30.2`.
- **Voxtral Mini Realtime / voxmlx** (`voxmlx==0.0.2`): `stream.py` has incremental mel, `encode_step`, encoder/decoder KV caches and an end-padding flush, but wraps microphone capture directly rather than exposing a feed API. Adapting that state machine is necessary; repeatedly calling offline `transcribe` is not streaming. Its default converted `mlx-community/Voxtral-Mini-4B-Realtime-6bit` is 3.61 GB + 15 MB tokenizer. The similarly named `...-2602-4bit` is an mlx-audio format, not automatically interchangeable with voxmlx's config/weight names.
- **Moonshine**: all three English streaming sizes were tested through the pinned native Metal library (medium failed as noted above). The official runtime was then installed and benchmarked successfully as `moonshine-voice-medium`; it does not suppress or work around the native truncation signal.

Additional MLX model downloads (~8.5 GB total for the compatible versions above) await approval. Python packages were inspected in disposable environments; no unverified MLX backend is advertised as working. Aug 22 `transcription-internals` bakeoff was not located in available local sources or scoped thread search.
