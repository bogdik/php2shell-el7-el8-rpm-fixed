#!/bin/bash
# Check a Remi PHP SRPM against the pinned SHA256 and the Remi 2026 ed25519 key.
# EL7 rpm cannot verify that signature (it reports the package unverifiable).
# GnuPG >= 2.2 can. Fingerprint is pinned; a missing key or a bad signature fails.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRPM=${1:?path to SRPM}
NAME=$(basename "$SRPM")
EXPECT=$(awk -v n="$NAME" '$1 !~ /^#/ && $2 == n { print $1 }' "$HERE/SOURCES.sha256")
[ -n "$EXPECT" ] || { echo "ERROR: no pin for $NAME" >&2; exit 1; }
GOT=$(sha256sum "$SRPM" | awk '{print $1}')
[ "$GOT" = "$EXPECT" ] || { echo "ERROR: $NAME sha256 $GOT != $EXPECT" >&2; exit 1; }

FPR=2E375FE24EDFF0F2E0D8E165ED5B58C5BEFA00E2
KEY=$HERE/keys/RPM-GPG-KEY-remi2026
[ -f "$KEY" ] || { echo "ERROR: missing $KEY" >&2; exit 1; }
shown=$(gpg --show-keys --with-colons "$KEY" | awk -F: '$1 == "fpr" { print $10; exit }')
[ "$shown" = "$FPR" ] || { echo "ERROR: Remi 2026 key fingerprint $shown != $FPR" >&2; exit 1; }

if ! gpg --version | head -1 | grep -Eq 'gpg \(GnuPG\) 2\.([2-9]|[1-9][0-9])'; then
  echo "ERROR: GnuPG >= 2.2 is required to verify Remi's ed25519 signature" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
python3 - "$SRPM" "$tmpdir/sig" "$tmpdir/header" << 'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
if data[:4] != b"\xed\xab\xee\xdb":
    raise SystemExit("not an RPM lead")

def parse(off):
    magic = data[off:off + 8]
    if magic[:3] != b"\x8e\xad\xe8":
        raise SystemExit(f"bad header magic at {off}")
    nindex, hsize = struct.unpack(">II", data[off + 8:off + 16])
    index = off + 16
    store = index + nindex * 16
    entries = []
    for i in range(nindex):
        tag, typ, ofs, count = struct.unpack(">iiii", data[index + i * 16:index + (i + 1) * 16])
        entries.append((tag, typ, ofs, count))
    end = store + hsize
    pad = (8 - ((end - off) % 8)) % 8
    return entries, store, end, end + pad

sig_entries, sig_store, _, header_off = parse(96)
_, _, header_end, _ = parse(header_off)
blob = None
for tag, typ, ofs, count in sig_entries:
    if tag == 267:
        blob = data[sig_store + ofs:sig_store + ofs + count]
        break
if not blob:
    raise SystemExit("SRPM has no signature tag 267")
open(sys.argv[2], "wb").write(blob)
open(sys.argv[3], "wb").write(data[header_off:header_end])
PY

gpg --batch --import "$KEY" >/dev/null
status=$(gpg --status-fd 1 --verify "$tmpdir/sig" "$tmpdir/header" 2>/dev/null || true)
long_id=${FPR: -16}
printf '%s\n' "$status" | grep -q "^\[GNUPG:\] GOODSIG ${long_id} " \
  || { echo "ERROR: $NAME signature is not GOODSIG ${long_id}" >&2; printf '%s\n' "$status" >&2; exit 1; }
printf '%s\n' "$status" | grep -q "^\[GNUPG:\] VALIDSIG ${FPR} " \
  || { echo "ERROR: $NAME signature is not VALIDSIG $FPR" >&2; exit 1; }
printf '%s %s\n' "$GOT" "$FPR" > "$SRPM.sigok"
echo "signature ok $NAME $FPR"
