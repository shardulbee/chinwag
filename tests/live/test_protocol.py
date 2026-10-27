"""Public HTTP/WS contract, including background pause cuts and stream isolation."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import pathlib
import sys
import unittest

import numpy as np
from aiohttp import web, WSMsgType
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "live"))
from server import create_app


class Backend:
    def begin(self):
        self.text = ""

    def feed(self, pcm):
        self.text = "hello" if not self.text else "hello world"
        return self.text

    def end(self):
        return self.text + "!" if self.text else ""

    def close(self):
        pass


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.chunks = []

        async def batch(request):
            fields = await request.post()
            self.chunks.append(fields["file"].file.read())
            await asyncio.sleep(.02)
            return web.json_response({"text": ["First sentence.", "Last words."][len(self.chunks) - 1]})

        batch_app = web.Application()
        batch_app.router.add_post("/v1/audio/transcriptions", batch)
        self.batch = TestServer(batch_app)
        await self.batch.start_server()
        app = create_app(str(self.batch.make_url("")).rstrip("/"))
        app["models"]["test"] = {"state": "ready", "busy": False, "backend": Backend(),
                                  "executor": ThreadPoolExecutor(max_workers=1)}
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.batch.close()

    async def test_whole_hypotheses_exactly_one_final_then_close(self):
        ws = await self.client.ws_connect("/v1/live?model=test")
        await ws.send_bytes(bytes(3200))
        self.assertEqual((await ws.receive_json())["text"], "hello")
        await ws.send_bytes(bytes(3200))
        self.assertEqual((await ws.receive_json())["text"], "hello world")
        await ws.send_json({"type": "end"})
        self.assertEqual(await ws.receive_json(), {"type": "final", "text": "hello world!", "model": "test"})
        self.assertEqual((await ws.receive()).type, WSMsgType.CLOSE)

    async def test_errors_are_structured_and_terminal(self):
        cases = [("missing", b"\x00\x00", "unknown_model"),
                 ("moonshine-streaming-medium", b"\x00\x00", "model_unavailable"),
                 ("test", b"\x00", "invalid_audio"),
                 ("test", bytes(64002), "invalid_audio"),
                 ("test", "not json", "invalid_message"),
                 ("test", '{"type":"other"}', "invalid_message")]
        for model, message, code in cases:
            ws = await self.client.ws_connect("/v1/live?model=" + model)
            if isinstance(message, bytes):
                await ws.send_bytes(message)
            else:
                await ws.send_str(message)
            self.assertEqual((await ws.receive_json())["error"]["code"], code)
            self.assertEqual((await ws.receive()).type, WSMsgType.CLOSE)

    async def test_busy_and_disconnected_stream_do_not_contaminate_next(self):
        first = await self.client.ws_connect("/v1/live?model=test")
        await first.send_bytes(bytes(3200))
        await first.receive_json()
        second = await self.client.ws_connect("/v1/live?model=test")
        self.assertEqual((await second.receive_json())["error"]["code"], "model_busy")
        await second.close()
        await first.close()
        third = await self.client.ws_connect("/v1/live?model=test")
        await third.send_json({"type": "end"})
        self.assertEqual((await third.receive_json())["text"], "")
        await third.close()

    async def test_pause_cut_runs_before_end_and_final_contains_all_pieces(self):
        ws = await self.client.ws_connect("/v1/live?model=chinwag-chunked")
        voice = np.full(16000, 3000, dtype="<i2").tobytes()
        silence = bytes(6400)
        # Irregular network framing must not change the pause cut.
        pcm = voice + silence
        for offset in range(0, len(pcm), 1262):
            await ws.send_bytes(pcm[offset:offset + 1262])
        partial = await asyncio.wait_for(ws.receive_json(), 2)
        self.assertEqual(partial["text"], "First sentence.")
        self.assertEqual(len(self.chunks), 1)  # Already transcribed without end.
        await ws.send_bytes(voice[:9600])
        await ws.send_json({"type": "end"})
        self.assertEqual((await ws.receive_json())["text"], "First sentence. Last words.")
        self.assertEqual(await ws.receive_json(), {"type": "final", "text": "First sentence. Last words.", "model": "chinwag-chunked"})
        self.assertEqual((await ws.receive()).type, WSMsgType.CLOSE)

    async def test_silent_chunked_stream_is_empty_final_without_batch_hallucination(self):
        ws = await self.client.ws_connect("/v1/live?model=chinwag-chunked")
        await ws.send_bytes(bytes(32000))
        await ws.send_json({"type": "end"})
        self.assertEqual((await ws.receive_json())["text"], "")
        self.assertEqual(self.chunks, [])
        await ws.close()

    async def test_model_discovery_and_browser_cors(self):
        response = await self.client.get("/v1/live/models", headers={"Origin": "https://puff.example"})
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")
        data = await response.json()
        self.assertEqual(data["audio"], {"sample_rate": 16000, "channels": 1, "encoding": "pcm_s16le"})
        self.assertIn("test", [model["id"] for model in data["data"]])


if __name__ == "__main__":
    unittest.main()
