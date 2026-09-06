#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
binary=$(mktemp "${TMPDIR:-/tmp}/chinwag-http-tests.XXXXXX")
trap 'rm -f "$binary"' EXIT
swiftc "$root/tests/http/HTTPServerTests.swift" "$root/macos/Chinwag/TranscriptionHTTPServer.swift" -o "$binary"
"$binary"
python3 "$root/tests/http/properties.py" --cases 50
