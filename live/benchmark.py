"""Feed a WAV in real time; measure from first audio and explicit end, not connect."""
import argparse
import asyncio
import json
import pathlib
import re
import time
import wave

from aiohttp import ClientSession, ClientTimeout, WSMsgType, FormData


def wer(reference, hypothesis):
    words = lambda text: re.findall(r"\b\w+\b", text.lower())
    ref, hyp = words(reference), words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        previous, row = row, [i]
        for j, other in enumerate(hyp, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (word != other)))
    return round(100 * row[-1] / max(1, len(ref)), 2)


async def race(http, base, model, pcm):
    events = []
    async with http.ws_connect(base.replace("http", "ws", 1) + "/v1/live", params={"model": model}) as ws:
        started = time.perf_counter()

        async def send():
            for offset in range(0, len(pcm), 3200):
                await asyncio.sleep(max(0, started + offset / 32000 - time.perf_counter()))
                await ws.send_bytes(pcm[offset:offset + 3200])
            await asyncio.sleep(max(0, started + len(pcm) / 32000 - time.perf_counter()))
            ended = time.perf_counter()
            await ws.send_json({"type": "end"})
            return ended

        sender = asyncio.create_task(send())
        try:
            async for message in ws:
                if message.type == WSMsgType.TEXT:
                    events.append({**json.loads(message.data), "at": time.perf_counter()})
            ended = await sender if not any(event["type"] == "error" for event in events) else None
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
    errors = [event for event in events if event["type"] == "error"]
    if errors:
        return {"model": model, "error": errors}
    finals = [event for event in events if event["type"] == "final"]
    assert len(finals) == 1, events
    partials = [event for event in events if event["type"] == "partial" and event["text"]]
    return {"model": model, "firstPartialMs": round((partials[0]["at"] - started) * 1000, 1) if partials else None,
            "endToFinalMs": round((finals[0]["at"] - ended) * 1000, 1),
            "partialCount": len(partials), "text": finals[0]["text"]}


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=pathlib.Path)
    parser.add_argument("--reference", type=pathlib.Path)
    parser.add_argument("--base", default="http://127.0.0.1:3213")
    parser.add_argument("--model", action="append")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--batch", default="http://127.0.0.1:3212")
    args = parser.parse_args()
    with wave.open(str(args.wav)) as audio:
        assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
        pcm = audio.readframes(audio.getnframes())
    results = []
    reference = args.reference.read_text() if args.reference else None
    async with ClientSession(timeout=ClientTimeout(total=240)) as http:
        async with http.get(args.base + "/v1/live/models") as response:
            models = (await response.json())["data"]
        for model in args.model or [m["id"] for m in models if m["state"] == "ready"]:
            # Exercise the hot path once before measuring the warm stream.
            await race(http, args.base, model, bytes(32000))
            result = await race(http, args.base, model, pcm)
            if reference and "text" in result:
                result["werPercent"] = wer(reference, result["text"])
            results.append(result)
            print(json.dumps(result), flush=True)
        form = FormData()
        form.add_field("model", "whisper-1")
        form.add_field("file", args.wav.read_bytes(), filename="benchmark.wav", content_type="audio/wav")
        started = time.perf_counter()
        async with http.post(args.batch + "/v1/audio/transcriptions", data=form) as response:
            response.raise_for_status()
            transcription = await response.json()
            result = {"model": "chinwag-batch", "firstPartialMs": None,
                      "endToFinalMs": round((time.perf_counter() - started) * 1000, 1), **transcription}
        if reference:
            result["werPercent"] = wer(reference, result["text"])
        results.append(result)
        print(json.dumps(result), flush=True)
    if args.output:
        args.output.write_text(json.dumps({"audioSeconds": len(pcm) / 32000, "reference": reference, "results": results}, indent=2) + "\n")


if __name__ == "__main__":
    asyncio.run(main())
