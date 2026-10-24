#!/bin/bash
# Download the five private-library archives and reject any hash mismatch
# before rpmbuild starts. No network is used from inside rpmbuild.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${1:?destination SOURCES directory}
mkdir -p "$DEST"

declare -A URLS=(
  [zlib-1.3.1.tar.gz]=https://zlib.net/fossils/zlib-1.3.1.tar.gz
  [libxml2-2.9.14.tar.xz]=https://download.gnome.org/sources/libxml2/2.9/libxml2-2.9.14.tar.xz
  [curl-8.4.0.tar.xz]=https://curl.se/download/curl-8.4.0.tar.xz
  [sqlite-autoconf-3460100.tar.gz]=https://www.sqlite.org/2024/sqlite-autoconf-3460100.tar.gz
  [postgresql-10.23.tar.bz2]=https://ftp.postgresql.org/pub/source/v10.23/postgresql-10.23.tar.bz2
)

expected_for() {
  local name=$1
  awk -v n="$name" '$1 !~ /^#/ && $2 == n { print $1 }' "$HERE/SOURCES.sha256"
}

for name in "${!URLS[@]}"; do
  expect=$(expected_for "$name")
  [ -n "$expect" ] || { echo "ERROR: no pin for $name" >&2; exit 1; }
  out=$DEST/$name
  if [ -f "$out" ]; then
    got=$(sha256sum "$out" | awk '{print $1}')
    if [ "$got" != "$expect" ]; then
      echo "Replacing $name: hash $got != $expect" >&2
      rm -f "$out"
    fi
  fi
  if [ ! -f "$out" ]; then
    curl -fL --retry 3 --max-time 300 -o "$out.partial" "${URLS[$name]}"
    mv "$out.partial" "$out"
  fi
  got=$(sha256sum "$out" | awk '{print $1}')
  if [ "$got" != "$expect" ]; then
    echo "ERROR: $name sha256 $got != pinned $expect" >&2
    exit 1
  fi
  echo "ok $name"
done
