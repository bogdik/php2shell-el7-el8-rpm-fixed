#!/bin/bash
# EL8 AppStream. Latest php:7.4 is Rocky 7.4.33-8; the SRPM already contains the patch.
# The script does not apply that patch again. Release 9 updates an older AppStream 7.4.
# Config stays at /etc/php.ini. If a closed 7.4.33 is already installed, no build is needed.
set -euo pipefail
umask 077

MODE=${1:---build}
case "$MODE" in
  --build|--finish|--install) ;;
  *) echo "Usage: bash $0 [--build|--finish|--install]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Run as root"
[ -f /etc/redhat-release ] && grep -Eq 'release 8([. ]|$)' /etc/redhat-release \
  || die "This script is for EL8 only"
[ "$(uname -m)" = x86_64 ] || die "This script is x86_64 only"

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=7.4.33
RELNUM=9
DIST=
RELEASE=$RELNUM
VERSION_ID=70433
CHECK_SYMBOL=1
CHECK_MULTIPART=1
SRPM_NAME=php-7.4.33-8.module+el8.10.0+40393+c071e357.src.rpm
SRPM_URL=https://dl.rockylinux.org/pub/rocky/8/AppStream/source/tree/Packages/p/$SRPM_NAME
TOP=/root/php74-el8-app-build
EXPECTED_GLOB='7.4.*module?el8*'
[ "$HERE" != "$TOP" ] || die "Do not place the script in $TOP"


current=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' php-common) || die "php-common is not installed"
case "$current" in
  *remi*) die "Remi is installed ($current). This script is AppStream only." ;;
  $EXPECTED_GLOB) ;;
  *) die "Expected AppStream php-common $EXPECTED_GLOB, found: $current" ;;
esac
rpm -q php-cli php-fpm >/dev/null || die "CLI and FPM must be installed"
for pkg in php php-litespeed php-oci8; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this update is FPM only"
  fi
done
if [ "$MODE" != --install ] \
   && php -n -r 'exit(PHP_VERSION_ID === 70433 ? 0 : 1);' >/dev/null 2>&1 \
   && nm -D "$(command -v php)" 2>/dev/null | grep -q ' zend_mm_safe_error_ex$' \
   && [ "$(php -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')" = /etc ]; then
  die "Installed AppStream 7.4.33 is already closed and reads /etc. No build needed."
fi

if [ "$MODE" = --install ]; then
  [ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = "$VERSION-$RELEASE" ] \
    || die "No successful build of $VERSION-$RELEASE. Run --build first"
  (cd "$TOP" && sha256sum -c RPMS.sha256)
fi

for conf in /etc/dnf/dnf.conf /etc/yum.conf; do
  [ -f "$conf" ] || continue
  proxy=$(awk -F= '/^[[:space:]]*proxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
  if [ -n "${proxy:-}" ]; then
    export http_proxy="$proxy" https_proxy="$proxy"
    break
  fi
done

prepare_spec() {
  local spec=$1 finish=$2
  local work
  work=$(mktemp "$TOP/SPECS/php.work.XXXXXX.spec")
  if [ "$finish" = 1 ]; then
    awk '$0 == "%prep" || $0 == "%build" { print; print "exit 0"; next } { print }' "$spec" > "$work"
  else
    cp -a "$spec" "$work"
    sed -i "0,/^Release:/s/^Release:.*/Release: ${RELNUM}%{?dist}/" "$work"
    if ! grep -Eq '109618|zend_mm_safe_error_ex' "$work"; then
      die "SRPM has no CVE-2026-109618 patch. There is nothing to reapply."
    fi
    if grep -q '%global _sysconfdir /etc/opt' "$work"; then
      die "Spec moves config under /etc/opt. AppStream needs /etc/php.ini"
    fi
  fi
  printf '%s\n' "$work"
}

opts=(--define 'runselftest 0' --define 'debug_package %{nil}' --define "_topdir $TOP")
if [ -n "$DIST" ]; then
  opts+=(--define "dist $DIST")
fi

if [ "$MODE" = --build ]; then
  dnf install -y dnf-plugins-core rpm-build gcc gcc-c++ make cpio curl patch
  if [ -f /etc/yum.repos.d/CentOS-Stream-PowerTools.repo ] || [ -f /etc/yum.repos.d/CentOS-PowerTools.repo ]; then
    dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
      || dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 || true
  fi
  rm -rf "$TOP"
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  if [ -f "$HERE/$SRPM_NAME" ]; then
    cp -a "$HERE/$SRPM_NAME" "$TOP/$SRPM_NAME"
  else
    curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
  fi
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm)
  mv "$TOP/SOURCES/"*.spec "$TOP/SPECS/php.spec"
  SPEC=$(prepare_spec "$TOP/SPECS/php.spec" 0)
  mv "$SPEC" "$TOP/SPECS/php.spec"
  SPEC=$TOP/SPECS/php.spec
  dnf builddep -y "$SPEC"
  rpmbuild -ba "${opts[@]}" "$SPEC" 2>&1 | tee "$TOP/build.log"
  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "RPMs were not built"
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Build ready. RPMs: $TOP/RPMS"
  echo "Install separately: bash $0 --install"
  exit 0
fi

if [ "$MODE" = --finish ]; then
  [ -x "$TOP/BUILD/php-$VERSION/build-fpm/sapi/fpm/php-fpm" ] \
    || die "Built FPM is not in $TOP/BUILD"
  installed_fpm=$(find "$TOP/BUILDROOT" -type f -name php-fpm -print -quit)
  [ -n "$installed_fpm" ] || die "BUILDROOT has no php-fpm, %install did not finish"
  [ -f "$TOP/SPECS/php.spec" ] || die "No spec"
  rm -f "$TOP/BUILD-OK" "$TOP/RPMS.sha256"
  find "$TOP/RPMS" -type f -name '*.rpm' -delete
  SPEC=$(prepare_spec "$TOP/SPECS/php.spec" 1)
  rpmbuild -bb --nocheck --noclean "${opts[@]}" "$SPEC" 2>&1 | tee -a "$TOP/build.log"
  rm -f "$SPEC"
  if find "$TOP/RPMS" -type f -name '*.rpm' -print0 \
      | xargs -0 -r rpm -qp --requires \
      | grep -q 'rpmlib(ShortCircuited)'; then
    die "RPMs are marked ShortCircuited and must not be installed"
  fi
  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "RPMs were not built"
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Packaged the build that was already there. RPMs: $TOP/RPMS"
  exit 0
fi

SPEC=$TOP/SPECS/php.spec
[ -f "$SPEC" ] || die "No spec. Run --build first"
mapfile -t from_spec < <(awk '/^%package / { print "php-" $2 }' "$SPEC")
from_spec+=(php)
declare -A built=()
for name in "${from_spec[@]}"; do
  built["$name"]=1
done
mapfile -t installed < <(rpm -qa --qf '%{NAME}\n' 'php*' | sort -u)
to_install=()
for name in "${installed[@]}"; do
  shopt -s nullglob
  matches=("$TOP"/RPMS/*/"${name}"-"${VERSION}"-"${RELNUM}"*.rpm)
  shopt -u nullglob
  if [ -z "${built[$name]:-}" ]; then
    echo "skip $name: this SRPM does not build it"
    continue
  fi
  if [ "${#matches[@]}" -ne 1 ]; then
    die "Expected one RPM for $name, found: ${#matches[@]}"
  fi
  to_install+=("${matches[0]}")
done
[ "${#to_install[@]}" -gt 0 ] || die "Nothing to install"
common=$(printf '%s\n' "${to_install[@]}" | grep '/php-common-' | head -1)
[ -n "$common" ] || die "php-common was not built"
new_ini=$(rpm -qpl "$common" | grep -E '/php\.ini$' || true)
[ "$new_ini" = "/etc/php.ini" ] || die "New php.ini: ${new_ini:-none}, need /etc/php.ini"
rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
tar -C / -czf "$backup/etc-php.tar.gz" etc/php.ini etc/php.d etc/php-fpm.d 2>/dev/null || true
rpm -Uvh "${to_install[@]}"
php -n -r "if (PHP_VERSION_ID !== $VERSION_ID) exit(1); echo PHP_VERSION, \"\\n\";"
now=$(php -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
[ "$now" = /etc ] || die "PHP reads ${now:-empty}, need /etc"
if [ "$CHECK_MULTIPART" = 1 ]; then
  php -n -r 'if (ini_get("max_multipart_body_parts") !== "-1") exit(1);'
fi
php -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 -m >/dev/null
if [ "$CHECK_SYMBOL" = 1 ]; then
  nm -D "$(command -v php)" | grep -q ' zend_mm_safe_error_ex$' \
    || die "zend_mm_safe_error_ex is missing from php"
fi
php-fpm -t
systemctl restart php-fpm
systemctl is-active --quiet php-fpm
pid=$(systemctl show php-fpm -p MainPID | cut -d= -f2)
cmp -s "$(command -v php-fpm)" "/proc/$pid/exe" || die "Running FPM does not match the installed binary"
echo "FPM restarted. Config archive: $backup"
grep -E '^[[:space:]]*listen[[:space:]]*=' /etc/php-fpm.d/www.conf || true
echo "Check nginx fastcgi_pass against this pool listen address."
