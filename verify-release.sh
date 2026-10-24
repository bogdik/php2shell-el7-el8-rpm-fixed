#!/bin/bash
# Read-only pre-publication checks. Safe to run on the release tree itself.
set -euo pipefail

# Prefer POSIX tools when invoked from Git Bash, whose inherited Windows PATH
# can otherwise resolve find.exe instead of GNU find.
PATH=/usr/bin:/bin:$PATH

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

die() { echo "ERROR: $*" >&2; exit 1; }

verify_manifest() {
  local dir=$1 manifest files listed
  manifest=$dir/SHA256SUMS
  [ -f "$manifest" ] || die "Missing $manifest"
  (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null)
  files=$(find "$dir" -type f -name '*.rpm' | wc -l)
  listed=$(wc -l < "$manifest")
  [ "$files" -eq "$listed" ] \
    || die "$manifest lists $listed RPMs, tree contains $files"
  echo "$dir: $files RPM checksums OK"
}

verify_manifest RPMS

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find . -type f -name '*.sh' -print0)
echo "shell syntax: OK"

patches=0
while IFS= read -r -d '' patch; do
  git apply --numstat -- "$patch" >/dev/null
  patches=$((patches + 1))
done < <(find . -type f -name '*.patch' -print0)
echo "patch syntax: $patches OK"

while IFS= read -r -d '' catalog; do
  ready=$(awk -F= '$1 == "ready" {print substr($0, 7)}' "$catalog")
  [ -z "$ready" ] || [ -d "$HERE/$ready" ] \
    || die "$catalog points to missing ready tree: $ready"
done < <(find . -type f -name CATALOG -print0)
echo "catalog ready paths: OK"

if find RPMS -type f -name '*-1.el7.remi.local.*.rpm' -print -quit | grep -q .; then
  die "Vulnerable EL7 -1 fixture found under RPMS"
fi
require_portable_el7() {
  local stream=$1
  local ver=$2
  local tree="RPMS/el7/remi/${stream}-rpm"
  local names rt
  [ -d "$tree" ] || die "Missing portable tree $tree"
  names=$(find "$tree" -type f -name '*.rpm' -printf '%f\n')
  printf '%s\n' "$names" | grep -q -- "-2.el7.remi.local" \
    && die "$tree still contains a non-portable -2 RPM"
  for needle in \
    "${stream}-php-${ver}-3.el7.remi.local.x86_64.rpm" \
    "${stream}-php-common-${ver}-3.el7.remi.local.x86_64.rpm" \
    "${stream}-php-cli-${ver}-3.el7.remi.local.x86_64.rpm" \
    "${stream}-php-fpm-${ver}-3.el7.remi.local.x86_64.rpm" \
    "php-el7-libs-1.0-1.el7.local.x86_64.rpm"
  do
    printf '%s\n' "$names" | grep -qx "$needle" || die "$tree is missing $needle"
  done
  rt=${ver%.*}
  printf '%s\n' "$names" | grep -qx "${stream}-runtime-${rt}-3.el7.remi.local.x86_64.rpm" \
    || die "$tree is missing ${stream}-runtime-${rt}-3"
  echo "$tree: portable -3 set present"
}

require_portable_el7 php84 8.4.27
require_portable_el7 php85 8.5.12
libs84=$(sha256sum RPMS/el7/remi/php84-rpm/x86_64/php-el7-libs-1.0-1.el7.local.x86_64.rpm | awk '{print $1}')
libs85=$(sha256sum RPMS/el7/remi/php85-rpm/x86_64/php-el7-libs-1.0-1.el7.local.x86_64.rpm | awk '{print $1}')
[ "$libs84" = "$libs85" ] || die "php-el7-libs copies in the php84 and php85 trees differ"

echo "release tree: OK"
