#!/usr/bin/env python3
"""Stream a 16 kHz mono PCM16 WAV to a /v1/live WebSocket and report latency. Standard library only."""
import argparse
import base64
import json
import os
import socket
import ssl
import struct
import threading
import time
import urllib.parse
import wave


def connect(url):
    parts = urllib.parse.urlsplit(url)
    secure = parts.scheme == 'wss'
    sock = socket.create_connection((parts.hostname, parts.port or (443 if secure else 80)), timeout=60)
    if secure:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=parts.hostname)
    key = base64.b64encode(os.urandom(16)).decode()
    path = parts.path + ('?' + parts.query if parts.query else '')
    sock.sendall((f'GET {path} HTTP/1.1\r\nHost: {parts.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                  f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
    response = b''
    while b'\r\n\r\n' not in response:
        chunk = sock.recv(1)
        assert chunk, 'connection closed during handshake'
        response += chunk
    assert response.startswith(b'HTTP/1.1 101'), response.decode(errors='replace')
    return sock


def send(sock, opcode, payload):
    mask = os.urandom(4)
    length = len(payload)
    header = bytes([0x80 | opcode]) + (bytes([0x80 | length]) if length < 126 else
                                       struct.pack('!BH', 0x80 | 126, length) if length < 65536 else
                                       struct.pack('!BQ', 0x80 | 127, length))
    sock.sendall(header + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload)))


def receive(sock):
    def exact(count):
        data = b''
        while len(data) < count:
            chunk = sock.recv(count - len(data))
            assert chunk, 'connection closed'
            data += chunk
        return data
    first, second = exact(2)
    length = second & 0x7f
    if length == 126:
        length = struct.unpack('!H', exact(2))[0]
    elif length == 127:
        length = struct.unpack('!Q', exact(8))[0]
    return first & 0x0f, exact(length)


def stream(url, path, realtime=True, frame_ms=100):
    """Returns partial count, first-partial and end-to-final latency, the final, and any error."""
    with wave.open(path) as audio:
        assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2), path
        pcm = audio.readframes(audio.getnframes())
    sock = connect(url)
    step = 32 * frame_ms
    start = time.perf_counter()
    def produce():
        try:
            for index, offset in enumerate(range(0, len(pcm), step)):
                if realtime:
                    time.sleep(max(0, start + index * frame_ms / 1000 - time.perf_counter()))
                send(sock, 2, pcm[offset:offset + step])
            result['ended'] = time.perf_counter()
            send(sock, 1, b'{"type":"end"}')
        except OSError:
            pass  # The server closed early; its error message is the result.
    result = {'audioSeconds': round(len(pcm) / 32000, 2), 'partials': 0, 'finals': 0}
    producer = threading.Thread(target=produce)
    producer.start()
    while True:
        opcode, payload = receive(sock)
        if opcode == 8:
            break
        message = json.loads(payload)
        if message['type'] == 'partial':
            result['partials'] += 1
            result.setdefault('firstPartialMs', round((time.perf_counter() - start) * 1000, 1))
        elif message['type'] == 'final':
            producer.join()
            result['finals'] += 1
            result['endToFinalMs'] = round((time.perf_counter() - result.pop('ended')) * 1000, 1)
            result['text'] = message['text']
        else:
            result['error'] = message.get('message')
    producer.join()
    result.pop('ended', None)
    sock.close()
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('wav')
    parser.add_argument('--fast', action='store_true', help='send without real-time pacing')
    args = parser.parse_args()
    print(json.dumps(stream(args.url, args.wav, realtime=not args.fast), indent=2))
