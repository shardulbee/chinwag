#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/chinwag-engine-tests.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT INT TERM

swiftc "$ROOT/macos/Chinwag/AudioDecoder.swift" \
  "$ROOT/macos/Chinwag/TranscriptionEngine.swift" \
  "$ROOT/tests/engine/TestDoubles.swift" \
  "$ROOT/tests/engine/AudioDecoderTests.swift" \
  -o "$BUILD/audio-tests"
"$BUILD/audio-tests"

swiftc -DENGINE_TEST "$ROOT/macos/Chinwag/TranscriptionEngine.swift" \
  "$ROOT/tests/engine/TestDoubles.swift" \
  "$ROOT/tests/engine/TranscriptionEngineTests.swift" \
  -o "$BUILD/engine-tests"
"$BUILD/engine-tests"
