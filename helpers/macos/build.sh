#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Usage: sh helpers/macos/build.sh NEW_PACKAGE_DIRECTORY' >&2
    exit 2
fi

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
parent_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
package_dir="$parent_dir/$(basename -- "$1")"
if [ -e "$package_dir" ] || [ -L "$package_dir" ]; then
    printf 'Package destination already exists: %s\n' "$package_dir" >&2
    exit 2
fi

stage=$(mktemp -d "$parent_dir/.netease-build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$stage/package/helpers/macos"
cp -R "$source_dir/plugin.toml" "$source_dir/README.md" "$source_dir/src" \
    "$source_dir/styles" "$source_dir/docs" "$stage/package/"
cp -R "$source_dir/helpers/windows" "$stage/package/helpers/"
cp "$source_dir/helpers/macos/Playback.swift" "$source_dir/helpers/macos/CurrentTrack.swift" \
    "$source_dir/helpers/macos/main.swift" "$source_dir/helpers/macos/cover.mjs" \
    "$source_dir/helpers/macos/track.mjs" "$source_dir/helpers/macos/build.sh" "$stage/package/helpers/macos/"
xcrun swiftc -O -module-cache-path "$stage/cache" \
    "$source_dir/helpers/macos/Playback.swift" "$source_dir/helpers/macos/CurrentTrack.swift" \
    "$source_dir/helpers/macos/main.swift" \
    -o "$stage/package/helpers/macos/netease-helper"
if ! mkdir -- "$package_dir"; then
    printf 'Package destination already exists: %s\n' "$package_dir" >&2
    exit 2
fi
cp -R "$stage/package/." "$package_dir/"
printf '%s\n' "$package_dir"
