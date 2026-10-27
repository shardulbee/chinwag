"""Loopback streaming ASR sidecar. Never opens the microphone or changes the app."""
import argparse
import asyncio
import ctypes as C
import io
import json
import logging
import pathlib
import wave
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from aiohttp import ClientSession, WSMsgType, web

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE_MODELS = {
    "nemotron-speech-streaming-en-0.6b": "en",
    "nemotron-3.5-asr-streaming-0.6b": "en-US",
    "parakeet-unified-en-0.6b": "en",
    "moonshine-streaming-tiny": "en",
    "moonshine-streaming-small": "en",
}
MAX_SECONDS = 120


class LiveError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


class NativeModel:
    def __init__(self, library, path, language):
        self.lib, self.language = library, language.encode()
        self.model = C.c_void_p()
        self.check(self.lib.live_load(str(path).encode(), C.byref(self.model)))

    def check(self, status):
        if status:
            raise LiveError("inference_failed", self.lib.transcribe_status_string(status).decode())

    def begin(self):
        self.session = C.c_void_p()
        self.check(self.lib.live_begin(self.model, self.language, C.byref(self.session)))

    def feed(self, pcm):
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
        self.check(self.lib.live_feed(self.session, audio.ctypes.data_as(C.POINTER(C.c_float)), len(audio)))
        return self.text()

    def text(self):
        return self.lib.transcribe_full_text(self.session).decode().strip()

    def end(self):
        self.check(self.lib.live_end(self.session))
        return self.text()

    def close(self):
        if self.session:
            self.lib.transcribe_session_free(self.session)
            self.session = None

    def unload(self):
        self.lib.transcribe_model_free(self.model)
        self.model = None


class MoonshineModel:
    def __init__(self):
        from moonshine_voice import Transcriber, ModelArch
        path = ROOT / "models/moonshine-voice/download.moonshine.ai/model/medium-streaming-en/quantized_26_08_21"
        if not (path / "streaming_config.json").is_file():
            raise FileNotFoundError("Official Moonshine medium not installed; run scripts/live fetch-models")
        self.model = Transcriber(path, ModelArch.MEDIUM_STREAMING, update_interval=0.5)
        self.stream = None

    def begin(self):
        self.lines, self.error = {}, None
        self.stream = self.model.create_stream(update_interval=0.5)
        self.stream.add_listener(self.update)
        self.stream.start()

    def update(self, event):
        if hasattr(event, "error"):
            self.error = event.error
        else:
            self.lines[event.line.line_id] = event.line

    def text(self):
        if self.error:
            raise LiveError("inference_failed", str(self.error))
        return " ".join(line.text.strip() for line in sorted(self.lines.values(), key=lambda line: line.start_time) if line.text.strip())

    def feed(self, pcm):
        self.stream.add_audio((np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768).tolist(), 16000)
        return self.text()

    def end(self):
        result = self.stream.stop()
        if result is None:
            raise LiveError("inference_failed", str(self.error or "Moonshine failed to finalize"))
        for line in result.lines:
            self.lines[line.line_id] = line
        return self.text()

    def close(self):
        if self.stream:
            self.stream.close()
            self.stream = None

    def unload(self):
        self.model.close()


def native_library():
    lib = C.CDLL(str(ROOT / "runtime/live-native.dylib"))
    signatures = {
        "live_init": ([C.c_char_p], C.c_int),
        "live_load": ([C.c_char_p, C.POINTER(C.c_void_p)], C.c_int),
        "live_begin": ([C.c_void_p, C.c_char_p, C.POINTER(C.c_void_p)], C.c_int),
        "live_feed": ([C.c_void_p, C.POINTER(C.c_float), C.c_int], C.c_int),
        "live_end": ([C.c_void_p], C.c_int),
        "transcribe_full_text": ([C.c_void_p], C.c_char_p),
        "transcribe_status_string": ([C.c_int], C.c_char_p),
        "transcribe_session_free": ([C.c_void_p], None),
        "transcribe_model_free": ([C.c_void_p], None),
    }
    for name, (args, result) in signatures.items():
        getattr(lib, name).argtypes, getattr(lib, name).restype = args, result
    status = lib.live_init(str(ROOT / "artifacts/transcribe-native-macos-arm64-metal").encode())
    if status:
        raise RuntimeError(f"Native backend initialization failed: {status}")
    return lib


def wav(pcm):
    out = io.BytesIO()
    with wave.open(out, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(pcm)
    return out.getvalue()


class Chunked:
    """Pause cuts run on the existing warm Cohere API while audio keeps arriving."""
    def __init__(self, http, emit, batch_url):
        self.http, self.emit, self.batch_url = http, emit, batch_url
        self.tail = bytearray()
        self.silence = 0
        self.scanned = 0
        self.voiced = False
        self.queue = asyncio.Queue(maxsize=16)
        self.parts = []
        self.worker = asyncio.create_task(self.run())

    async def feed(self, pcm):
        # Analyse fixed 20ms windows, independent of client WebSocket frame size.
        self.tail.extend(pcm)
        while self.scanned + 640 <= len(self.tail):
            block = np.frombuffer(self.tail[self.scanned:self.scanned + 640], dtype="<i2").astype(np.float32)
            speech = np.sqrt(np.mean(block * block)) >= 300
            self.voiced |= speech
            self.silence = 0 if speech else self.silence + 640
            self.scanned += 640
            # Bound uninterrupted speech too, so end never starts a full-utterance job.
            if self.voiced and ((self.silence >= 6400 and self.scanned >= 32000) or self.scanned >= 256000):
                await self.cut(self.scanned)

    async def cut(self, count):
        if self.worker.done():
            await self.worker
        if self.voiced:
            try:
                self.queue.put_nowait(bytes(self.tail[:count]))
            except asyncio.QueueFull:
                raise LiveError("overloaded", "Cohere cannot keep up with incoming audio")
        del self.tail[:count]
        self.scanned = self.silence = 0
        self.voiced = False

    async def run(self):
        from aiohttp import FormData
        while (pcm := await self.queue.get()) is not None:
            form = FormData()
            form.add_field("model", "whisper-1")
            form.add_field("file", wav(pcm), filename="chunk.wav", content_type="audio/wav")
            async with self.http.post(self.batch_url + "/v1/audio/transcriptions", data=form) as response:
                result = await response.json()
                if response.status != 200:
                    raise LiveError("batch_failed", f"Cohere API {response.status}: {result}")
                self.parts.append(result["text"].strip())
                await self.emit("partial", " ".join(self.parts))

    async def end(self):
        # Include a final sub-20ms voiced remainder rather than dropping it as silence.
        if self.tail[self.scanned:]:
            block = np.frombuffer(self.tail[self.scanned:], dtype="<i2").astype(np.float32)
            self.voiced |= np.sqrt(np.mean(block * block)) >= 300
        await self.cut(len(self.tail))
        await self.queue.put(None)
        await self.worker
        return " ".join(self.parts)

    async def close(self):
        self.worker.cancel()
        await asyncio.gather(self.worker, return_exceptions=True)


@web.middleware
async def cors(request, handler):
    response = web.Response() if request.method == "OPTIONS" else await handler(request)
    if not isinstance(response, web.WebSocketResponse):
        response.headers.update({"Access-Control-Allow-Origin": "*",
                                 "Access-Control-Allow-Methods": "GET, OPTIONS",
                                 "Access-Control-Allow-Private-Network": "true"})
    return response


async def live(request):
    # A close handshake acknowledges that model state has actually been released.
    ws = web.WebSocketResponse(max_msg_size=MAX_SECONDS * 32000, heartbeat=20, autoclose=False)
    await ws.prepare(request)
    app = request.app
    model_id = request.query.get("model", "chinwag-chunked")
    slot = app["models"].get(model_id)
    acquired = False
    chunked = None
    last = ""

    async def emit(kind, text):
        nonlocal last
        if kind == "final" or (text and text != last):
            await ws.send_json({"type": kind, "text": text, "model": model_id})
            last = text

    async def call(method, *args):
        return await asyncio.get_running_loop().run_in_executor(slot["executor"], method, *args)

    try:
        if slot is None:
            raise LiveError("unknown_model", f"Unknown model: {model_id}; see /v1/live/models")
        if slot["state"] != "ready":
            raise LiveError("model_unavailable", slot.get("error", "Model is not loaded"))
        if slot["busy"]:
            raise LiveError("model_busy", "This model already has an active stream; retry after it closes")
        slot["busy"] = acquired = True
        if model_id == "chinwag-chunked":
            chunked = Chunked(app["http"], emit, app["batch_url"])
        else:
            await call(slot["backend"].begin)
        total = 0
        # Explicit end required. Both idle and total audio limits bound abandoned clients.
        async with asyncio.timeout(180):
            while True:
                message = await ws.receive(timeout=15)
                if message.type == WSMsgType.BINARY:
                    pcm = message.data
                    if not pcm or len(pcm) % 2 or len(pcm) > 64000:
                        raise LiveError("invalid_audio", "Expected nonempty signed PCM16 little-endian frames of at most 64000 bytes")
                    total += len(pcm)
                    if total > MAX_SECONDS * 32000:
                        raise LiveError("audio_too_long", f"Maximum audio duration is {MAX_SECONDS} seconds")
                    if chunked:
                        await chunked.feed(pcm)
                    else:
                        await emit("partial", await call(slot["backend"].feed, pcm))
                elif message.type == WSMsgType.TEXT:
                    try:
                        control = json.loads(message.data)
                    except ValueError:
                        raise LiveError("invalid_message", 'Expected {"type":"end"}')
                    if control != {"type": "end"}:
                        raise LiveError("invalid_message", 'Expected {"type":"end"}')
                    text = "" if total == 0 else (await chunked.end() if chunked else await call(slot["backend"].end))
                    await emit("final", text)
                    break
                elif message.type == WSMsgType.ERROR:
                    raise LiveError("invalid_message", "Malformed or oversized WebSocket message")
                elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED):
                    break
    except (LiveError, TimeoutError) as error:
        if not ws.closed:
            await ws.send_json({"type": "error", "error": {"code": getattr(error, "code", "timeout"),
                                 "message": str(error) or "Stream timed out"}, "model": model_id})
    except Exception:
        logging.exception("Stream failed for %s", model_id)
        if not ws.closed:
            await ws.send_json({"type": "error", "error": {"code": "internal_error", "message": "Inference failed; inspect the sidecar log"}, "model": model_id})
    finally:
        if chunked:
            await chunked.close()
        elif acquired:
            await call(slot["backend"].close)
        if acquired:
            slot["busy"] = False
        await ws.close()
    return ws


async def models(request):
    return web.json_response({"object": "list", "audio": {"sample_rate": 16000, "channels": 1, "encoding": "pcm_s16le"},
                              "data": [{"id": key, **{k: v for k, v in slot.items() if k not in ("backend", "executor")},
                                        **({"default": True} if key == "parakeet-unified-en-0.6b" else {})}
                                       for key, slot in request.app["models"].items()]})


def create_app(batch_url="http://127.0.0.1:3212"):
    app = web.Application(middlewares=[cors])
    app["models"] = {
        "chinwag-chunked": {"state": "ready", "busy": False, "backend_type": "pause-chunked-cohere"},
        "moonshine-streaming-medium": {
            "state": "unavailable", "busy": False, "backend_type": "transcribe.cpp-metal",
            "error": "Failed 24.88s validation: native 0.2.1 retains a truncation flag from a looping partial decode, even after text recovers. Not serving potentially incomplete finals.",
        },
    }
    app["batch_url"] = batch_url
    app.router.add_get("/v1/live", live)
    app.router.add_get("/v1/live/models", models)

    async def start(app):
        app["http"] = ClientSession()

    async def stop(app):
        await app["http"].close()
        for slot in app["models"].values():
            if "executor" in slot:
                if isinstance(slot.get("backend"), (NativeModel, MoonshineModel)):
                    await asyncio.get_running_loop().run_in_executor(slot["executor"], slot["backend"].unload)
                slot["executor"].shutdown(wait=True)

    app.on_startup.append(start)
    app.on_cleanup.append(stop)
    return app


async def load_models(app):
    lib = native_library()
    for name, language in NATIVE_MODELS.items():
        slot = {"state": "loading", "busy": False, "backend_type": "transcribe.cpp-metal",
                "executor": ThreadPoolExecutor(max_workers=1, thread_name_prefix=name)}
        app["models"][name] = slot
        try:
            path = ROOT / f"models/live/{name}-Q8_0.gguf"
            if not path.is_file():
                raise FileNotFoundError(f"Model not installed: {path.name}")
            slot["backend"] = await asyncio.get_running_loop().run_in_executor(slot["executor"], NativeModel, lib, path, language)
            slot["state"] = "ready"
        except Exception as error:
            slot.update(state="unavailable", error=str(error))
            logging.exception("Cannot load %s", name)

    slot = {"state": "loading", "busy": False, "backend_type": "moonshine-voice-onnx",
            "executor": ThreadPoolExecutor(max_workers=1, thread_name_prefix="moonshine-voice")}
    app["models"]["moonshine-voice-medium"] = slot
    try:
        slot["backend"] = await asyncio.get_running_loop().run_in_executor(slot["executor"], MoonshineModel)
        slot["state"] = "ready"
    except Exception as error:
        slot.update(state="unavailable", error=str(error))
        logging.exception("Cannot load official Moonshine medium")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=3213)
    parser.add_argument("--batch-url", default="http://127.0.0.1:3212")
    args = parser.parse_args()
    app = create_app(args.batch_url)
    app.on_startup.append(load_models)
    web.run_app(app, host="127.0.0.1", port=args.port)
