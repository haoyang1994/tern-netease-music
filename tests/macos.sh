#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
plugin_dir=$(dirname -- "$test_dir")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tern-netease-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

node --check "$plugin_dir/helpers/macos/track.mjs"
node --check "$plugin_dir/helpers/macos/cover.mjs"
node --test "$test_dir/track.test.mjs"
xcrun swiftc -module-cache-path "$scratch/cache" "$plugin_dir/helpers/macos/CurrentTrack.swift" \
    "$test_dir/CurrentTrackTests.swift" -o "$scratch/test-track"
"$scratch/test-track" "$scratch"
