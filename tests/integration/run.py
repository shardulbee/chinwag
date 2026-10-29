#!/usr/bin/env python3
"""Real Metal/API smoke test. Optionally compare an existing server with --baseline URL."""
import argparse
import concurrent.futures
import json
import pathlib
import statistics
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import live

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline')
parser.add_argument('--repetitions', type=int, default=8)
parser.add_argument('--batch-model', default='parakeet-unified-en-0.6b', help='dictation and batch model setting')
args = parser.parse_args()
models = pathlib.Path.home() / '.local/share/chinwag/models'
assert (models / 'parakeet-unified-en-0.6b-Q8_0.gguf').is_file(), 'Install the model by launching Chinwag first'
native = root / 'artifacts/transcribe-native-macos-arm64-metal'
swift = root / 'macos/Chinwag'


def health(base):
    with urllib.request.urlopen(base + '/healthz', timeout=2) as response:
        return json.load(response)


def transcribe(base, audio, format='json'):
    boundary = 'ChinwagIntegrationBoundary'
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-1\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\n{format}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="speech.wav"\r\n'
            'Content-Type: audio/wav\r\n\r\n').encode() + audio + f'\r\n--{boundary}--\r\n'.encode()
    request = urllib.request.Request(base + '/v1/audio/transcriptions', data=body,
                                    headers={'Content-Type': 'multipart/form-data; boundary=' + boundary})
    start = time.perf_counter()
    with urllib.request.urlopen(request, timeout=125) as response:
        data = response.read()
    elapsed = (time.perf_counter() - start) * 1000
    text = data.decode().strip() if format == 'text' else json.loads(data)['text']
    assert 'recording' in text.lower(), text
    return elapsed, text


with tempfile.TemporaryDirectory(prefix='chinwag-integration-') as directory:
    directory = pathlib.Path(directory)
    audio = directory / 'speech.wav'
    sentence = 'This recording checks local speech recognition. The model stays loaded, and the application responds without sending audio to the cloud. '
    subprocess.run(['say', '-r', '180', '-o', str(audio), '--data-format=LEI16@16000', sentence * args.repetitions], check=True)
    contents = audio.read_bytes()
    subprocess.run(['xcrun', 'clang', '-O2', '-mmacosx-version-min=14.0', '-c',
                    str(swift / 'Native/ChinwagNativeBridge.c'), '-o', str(directory / 'bridge.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-import-objc-header',
                    str(swift / 'Native/Chinwag-Bridging-Header.h'), '-L', str(native), '-ltranscribe',
                    '-Xlinker', '-rpath', '-Xlinker', str(native), str(directory / 'bridge.o'),
                    *[str(swift / name) for name in ['AudioDecoder.swift', 'NativeModel.swift',
                      'TranscriptionEngine.swift', 'TranscriptionHTTPServer.swift']],
                    str(root / 'tests/integration/EngineHost.swift'), '-o', str(directory / 'host')], check=True)
    host = subprocess.Popen([str(directory / 'host'), str(models), str(native), '-transcriptionModel', args.batch_model],
                            stdin=subprocess.PIPE)
    try:
        base = 'http://127.0.0.1:3219'
        for _ in range(240):
            assert host.poll() is None, 'engine host exited'
            try:
                status = health(base)
                assert status['pid'] == host.pid
                assert status['state'] != 'error', status
                if status['state'] == 'ready':
                    break
            except urllib.error.URLError:
                pass
            time.sleep(0.25)
        else:
            raise AssertionError('model did not load')
        assert status['backend'] == 'Metal'
        servers = {'swift': base}
        if args.baseline:
            servers['baseline'] = args.baseline.rstrip('/')
        for name, endpoint in servers.items():
            transcribe(endpoint, contents)  # Exclude first inference from warm timing.
        timings = {name: [] for name in servers}
        transcripts = {}
        for _ in range(5):
            for name, endpoint in servers.items():
                elapsed, text = transcribe(endpoint, contents)
                timings[name].append(round(elapsed, 1))
                transcripts[name] = text
        for format in ['text', 'verbose_json']:
            transcribe(base, contents, format)
        if args.baseline:
            assert transcripts['swift'] == transcripts['baseline'], 'transcripts differ'
        with urllib.request.urlopen(base + '/v1/live/models', timeout=2) as response:
            assert json.load(response)['data'] == [{'id': 'parakeet-unified-en-0.6b', 'state': 'ready', 'default': True}]
        # Two live streams and a batch request overlap on the one warm model; none may be rejected.
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            streams = [pool.submit(live.stream, 'ws://127.0.0.1:3219/v1/live?model=parakeet-unified-en-0.6b',
                                   str(audio), realtime=False) for _ in range(2)]
            batch = pool.submit(transcribe, base, contents)
            results = [future.result() for future in streams]
            batch.result()
        for result in results:
            assert result['finals'] == 1 and result['partials'] > 0 and 'error' not in result, result
            assert 'recording' in result['text'].lower(), result
        assert live.stream('ws://127.0.0.1:3219/v1/live?model=unknown', str(audio), realtime=False)['error']
        print(json.dumps({'live': {key: results[0][key] for key in ['partials', 'endToFinalMs', 'text']},'audioSeconds': health(base)['lastTranscription']['audioSeconds'],
                          'warmRequestMs': timings,
                          'medianMs': {name: round(statistics.median(values), 1) for name, values in timings.items()},
                          'matchingTranscripts': not args.baseline or transcripts['swift'] == transcripts['baseline']}, indent=2))
    finally:
        host.stdin.close()
        host.wait(timeout=10)
    try:
        health(base)
    except urllib.error.URLError:
        print('API stopped with host. Real Metal integration passed.')
    else:
        raise AssertionError('API survived host exit')
