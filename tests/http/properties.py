#!/usr/bin/env python3
"""Generated HTTP properties against the real server and an input-echoing engine.

Run: python3 tests/http/properties.py [--seed 42] [--cases 250]
Failures report a reproducible seed and case; no automatic shrinking.
"""
import argparse
import base64
import http.client
import json
import pathlib
import random
import select
import socket
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seed', type=int, default=20260906)
parser.add_argument('--cases', type=int, default=250)
args = parser.parse_args()
rng = random.Random(args.seed)


def quote(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def multipart(boundary, audio, filename, language, shuffled=False, mixed_case=False):
    parts = [(['Content-Disposition: form-data; name="file"; filename=' + quote(filename),
               'Content-Type: audio/wav'], audio),
             (['Content-Disposition: form-data; name="language"'], language.encode()),
             (['Content-Disposition: form-data; name="model"'], b'whisper-1')]
    if shuffled:
        rng.shuffle(parts)
    result = bytearray()
    for headers, value in parts:
        if mixed_case:
            headers = [header.replace('Content-', 'cOnTeNt-').replace('Disposition', 'dIsPoSiTiOn').replace('Type', 'tYpE') for header in headers]
        result.extend(('--' + boundary + '\r\n' + '\r\n'.join(headers) + '\r\n\r\n').encode())
        result.extend(value + b'\r\n')
    return bytes(result) + ('--' + boundary + '--\r\n').encode()


def wire(body, boundary, chunked=False, mixed_case=False, extra=b''):
    framing = b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
    encoded = body
    if chunked:
        framing = b'Transfer-Encoding: chunked\r\n'
        encoded = bytearray()
        offset = 0
        while offset < len(body):
            size = min(rng.randint(1, 1024), len(body) - offset)
            encoded.extend(f'{size:x}\r\n'.encode() + body[offset:offset + size] + b'\r\n')
            offset += size
        encoded.extend(b'0\r\n\r\n')
    headers = b'Host: localhost\r\nContent-Type: multipart/form-data; boundary=' + quote(boundary).encode() + b'\r\n' + framing
    if mixed_case:
        headers = headers.replace(b'Content-', b'cOnTeNt-').replace(b'Transfer-Encoding', b'tRaNsFeR-eNcOdInG')
    return b'POST /v1/audio/transcriptions HTTP/1.1\r\n' + headers + extra + b'\r\n' + encoded


def exchange(payload, fragmented=False):
    with socket.create_connection(('127.0.0.1', 33213), timeout=5) as connection:
        connection.settimeout(5)
        try:
            offset = 0
            while offset < len(payload):
                size = rng.randint(1, 257) if fragmented else len(payload)
                connection.sendall(payload[offset:offset + size])
                offset += size
        except (BrokenPipeError, ConnectionResetError):
            pass
        response = http.client.HTTPResponse(connection)
        response.begin()
        return response.status, json.loads(response.read())


def calls():
    return exchange(b'GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n')[1]['calls']


with tempfile.TemporaryDirectory(prefix='chinwag-properties-') as directory:
    binary = pathlib.Path(directory) / 'host'
    subprocess.run(['swiftc', '-g', '-DHTTP_FUZZ', '-DHTTP_PBT',
                    str(root / 'tests/http/HTTPServerTests.swift'), str(root / 'tests/http/FuzzHost.swift'),
                    str(root / 'macos/Chinwag/TranscriptionHTTPServer.swift'), '-o', str(binary)], check=True)
    host = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    case = -1
    checks = 0
    try:
        assert select.select([host.stdout], [], [], 10)[0], 'host startup timeout'
        assert host.stdout.readline().strip() == b'ready'
        for case in range(args.cases):
            boundary = 'boundary-' + str(rng.getrandbits(64))
            # Include delimiter prefixes and every possible byte across the generated cases.
            audio = bytes(rng.randrange(256) for _ in range(rng.randint(1, 8192))) + ('\r\n--' + boundary + '-not-a-delimiter').encode()
            filename = rng.choice(['voice.wav', 'voice;notes.wav', 'voice "quoted".wav', 'voice\\notes.wav'])
            language = rng.choice(['', 'en', 'fr', 'de', 'ja'])
            expected = dict(bytes=base64.b64encode(audio).decode(), filename=filename, mimeType='audio/wav', language=language)
            original = multipart(boundary, audio, filename, language)
            variants = [(wire(original, boundary), False),
                        (wire(original, boundary), True),
                        (wire(original, boundary, chunked=True), True),
                        (wire(multipart(boundary, audio, filename, language, True, True), boundary, mixed_case=True), False)]
            before = calls()
            for payload, fragmented in variants:
                status, result = exchange(payload, fragmented)
                assert status == 200, (status, result, filename)
                actual = json.loads(result['text'])
                assert actual == expected, {key: (str(expected[key])[:120], str(actual.get(key))[:120]) for key in expected if actual.get(key) != expected[key]}
                checks += 1
            assert calls() == before + len(variants), 'not exactly one engine invocation per valid request'
            for extra in [b'Content-Length: 0\r\n', b'Transfer-Encoding: chunked\r\n', b'Origin: null\r\n', b'Sec-Fetch-Site: cross-site\r\n']:
                status, _ = exchange(wire(original, boundary, extra=extra))
                assert status in (400, 403), 'conflicting framing/browser request accepted'
                assert calls() == before + len(variants), 'rejected request invoked engine'
                checks += 1
        for size in [25 * 1024 * 1024 + rng.randint(1, 1000) for _ in range(3)]:
            before = calls()
            status, _ = exchange(wire(multipart('b', b'x' * size, 'a.wav', ''), 'b'))
            assert status == 413 and calls() == before, 'oversize upload reached engine'
            checks += 1
        print(f'Properties passed: seed={args.seed}, generated cases={args.cases}, request checks={checks}.')
    except BaseException:
        print(f'Reproduce with --seed {args.seed} --cases {case + 1}; failing case={case}')
        raise
    finally:
        host.stdin.close()
        host.wait(timeout=10)
    assert host.returncode == 0
