#!/usr/bin/env python3
"""Seeded black-box mutation fuzzing of the real HTTP server.

No model or installed app is used. Reproduce with --seed and --cases.
"""
import argparse
import collections
import concurrent.futures
import errno
import itertools
import pathlib
import random
import select
import socket
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seed', type=int, default=20260906)
parser.add_argument('--cases', type=int, default=20000)
parser.add_argument('--asan', action='store_true', help='Requires a compatible AddressSanitizer runtime')
parser.add_argument('--slow', action='store_true', help='Also exercise the 30-second incomplete-request deadline')
args = parser.parse_args()
rng = random.Random(args.seed)
body = b'--b\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n\r\naudio\r\n--b--\r\n'
head = b'POST /v1/audio/transcriptions HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=b\r\n'


def request(payload):
    return head + b'Content-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload


seeds = [request(body), b'GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n',
         head + b'Transfer-Encoding: chunked\r\n\r\n' + hex(len(body))[2:].encode() + b'\r\n' + body + b'\r\n0\r\n\r\n']
tokens = [b'\r\n', b'\r\n\r\n', b'--', b'"', b'\\', b'\x00', b'\xff', b';', b'=', b':',
          b'Content-Length: 0\r\n', b'Transfer-Encoding: chunked\r\n', b'Origin: null\r\n',
          b'7fffffffffffffff', b'-1', b'+1', b'0', b'\t', 'é'.encode(), b'--b--', b'filename=', b'name=']


def mutate(data):
    for _ in range(rng.randint(1, 6)):
        pos = rng.randrange(len(data) + 1)
        op = rng.randrange(5)
        if op == 0:
            data = data[:pos] + rng.choice(tokens) + data[pos:]
        elif op == 1:
            data = data[:pos] + data[pos + rng.randint(1, 40):]
        elif op == 2:
            data = data[:pos] + bytes([rng.randrange(256)]) + data[pos + 1:]
        elif op == 3:
            data = data[:pos]
        else:
            data = data[:pos] + data[max(0, pos - 30):pos] + data[pos:]
    return data


connections = itertools.count()


def connect():
    # Spread short-lived connections across test listeners to avoid TIME_WAIT exhaustion.
    for _ in range(64000):
        index = next(connections)
        connection = socket.socket()
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        connection.settimeout(3)
        try:
            connection.bind(('127.0.0.1', 20000 + (index // 8) % 8000))
            connection.connect(('127.0.0.1', 33213 + index % 8))
            return connection
        except OSError as error:
            connection.close()
            if error.errno not in (errno.EADDRINUSE, errno.EADDRNOTAVAIL):
                raise
    raise RuntimeError('Test connection pool exhausted')


def exchange(data, fragmented=False):
    with connect() as connection:
        try:
            if fragmented:
                for offset in range(0, len(data), 7):
                    connection.sendall(data[offset:offset + 7])
            else:
                connection.sendall(data)
            connection.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            pass
        response = bytearray()
        try:
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                response.extend(chunk)
                assert len(response) < 1024 * 1024, 'unbounded response'
        except ConnectionResetError:
            pass
        return bytes(response)


with tempfile.TemporaryDirectory(prefix='chinwag-fuzz-') as directory:
    directory = pathlib.Path(directory)
    binary = directory / 'host'
    subprocess.run(['swiftc', '-g', *(['-sanitize=address'] if args.asan else []), '-DHTTP_FUZZ',
                    str(root / 'tests/http/HTTPServerTests.swift'),
                    str(root / 'tests/http/FuzzHost.swift'),
                    str(root / 'macos/Chinwag/TranscriptionHTTPServer.swift'), '-o', str(binary)], check=True)
    with (directory / 'errors').open('w+') as errors:
        host = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        if not select.select([host.stdout], [], [], 20)[0]:
            host.terminate()
            host.wait(timeout=5)
            raise RuntimeError('Host never reached main; check sanitizer/runtime compatibility')
        assert host.stdout.readline().strip() == b'ready', 'host failed to start'
        counts = collections.Counter()
        started = time.monotonic()
        current = b''
        index = -1
        try:
            probes = {
                'signed Content-Length': request(body).replace(b'Content-Length: ', b'Content-Length: +'),
                'invalid closing boundary': request(body.replace(b'--b--\r\n', b'--b--garbage\r\n')),
                'duplicate disposition': request(body.replace(b'Content-Disposition:', b'Content-Disposition: form-data; name="evil"\r\nContent-Disposition:')),
            }
            for name, payload in probes.items():
                current = payload
                status = exchange(payload).splitlines()[0]
                assert b'400 Bad Request' in status, (name, status)
            for payload in [
                head + b'Content-Length: 999999999\r\n\r\n',
                head + b'Transfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n',
                request(body.replace(b'audio', b'x' * (25 * 1024 * 1024 + 1))),
                request(body.replace(b'--b--', b'--b\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n' + b'x' * 65537 + b'\r\n--b--')),
            ]:
                current = payload
                assert b'413 ' in exchange(payload).splitlines()[0], 'size limit not enforced'
            for index in range(args.cases):
                # Preserve outer framing in half the cases to reach multipart parsing.
                current = request(mutate(body)) if index % 2 else mutate(rng.choice(seeds))
                response = exchange(current, fragmented=index % 97 == 0)
                assert host.poll() is None, 'server crashed'
                assert response.startswith(b'HTTP/1.1 '), 'missing HTTP response'
                counts[response.split(b' ', 2)[1].decode()] += 1
                if index % 1000 == 0:
                    assert b'200 OK' in exchange(seeds[1]), 'server became unresponsive'
            # Exercise concurrent requests and disconnects on the same listener.
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                responses = list(pool.map(exchange, [seeds[i % 3] for i in range(1000)]))
            assert all(b'200 OK' in response for response in responses)
            idle = [connect() for _ in range(64)]
            try:
                assert b'200 OK' in exchange(seeds[1]), 'idle clients blocked health endpoint'
            finally:
                for connection in idle:
                    connection.close()
            if args.slow:
                with connect() as connection:
                    connection.settimeout(35)
                    connection.sendall(b'GET /healthz HTTP/1.1\r\n')
                    began = time.monotonic()
                    response = connection.recv(4096)
                    assert b'408 ' in response and 28 <= time.monotonic() - began <= 35, 'incomplete request deadline'
                print('Incomplete-request timeout and idle-client responsiveness passed.')
            print(f'seed={args.seed}: {args.cases} mutations + 1000 concurrent valid requests; statuses={dict(counts)}; seconds={time.monotonic() - started:.1f}')
        except BaseException:
            failure = root / 'tests/http/fuzz-failure.bin'
            failure.write_bytes(current)
            errors.flush(); errors.seek(0)
            print(errors.read())
            print(f'Reproducer: {failure}; seed={args.seed}; case={index}')
            raise
        finally:
            host.stdin.close()
            host.wait(timeout=10)
        errors.flush(); errors.seek(0)
        diagnostics = errors.read()
        assert host.returncode == 0 and 'ERROR: AddressSanitizer' not in diagnostics, diagnostics
        print('No crashes or hangs detected.' + (' No AddressSanitizer errors.' if args.asan else ' Swift runtime checks enabled; no sanitizer.'))
