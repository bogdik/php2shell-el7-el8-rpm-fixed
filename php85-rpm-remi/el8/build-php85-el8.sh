#!/bin/bash
# EL8, Remi module php:remi-8.5. System PHP, not SCL.
# Config stays at /etc/php.ini, /etc/php.d, /etc/php-fpm.d.
# Base: php-8.5.12-1.remi.src.rpm. Release 2.module_php.8.5.el8.remi.
# Official 8.5.12 does not disable upload progress: the filename
# is still written into the session. The patch silences that callback.
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
VERSION=8.5.12
RELNUM=2
DIST=.module_php.8.5.el8.remi
RELEASE=${RELNUM}${DIST}
VERSION_ID=80512
CHECK_SYMBOL=0
CHECK_MULTIPART=0
SRPM_NAME=php-8.5.12-1.remi.src.rpm
SRPM_URL=https://rpms.remirepo.net/SRPMS/$SRPM_NAME
PATCH_NAME=php-8.5.12-upload-progress-off.patch
TOP=/root/php85-el8-remi-build
EXPECTED_GLOB='8.5.12-*module_php.8.5.el8.remi*'
[ "$HERE" != "$TOP" ] || die "Do not place the script in $TOP"

if [ -f "$HERE/$PATCH_NAME" ]; then
  PATCH=$HERE/$PATCH_NAME
elif [ -f "$HERE/../el7/$PATCH_NAME" ]; then
  PATCH=$HERE/../el7/$PATCH_NAME
else
  PATCH=$HERE/$PATCH_NAME
fi

current=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' php-common) || die "php-common is not installed"
case "$current" in
  $EXPECTED_GLOB) ;;
  *) die "Expected Remi php-common $EXPECTED_GLOB, found: $current" ;;
esac
rpm -q php-cli php-fpm >/dev/null || die "CLI and FPM must be installed"
for pkg in php php-litespeed php-oci8; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this update is FPM only"
  fi
done

if [ "$MODE" = --install ]; then
  [ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = "$VERSION-$RELEASE" ] \
    || die "No successful build of $VERSION-$RELEASE. Run --build first"
  (cd "$TOP" && sha256sum -c RPMS.sha256)
else
  [ -f "$PATCH" ] || die "Missing patch $PATCH"
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
    local base last new apply
    base=$(basename "$PATCH")
    last=$(awk '
      /^Patch[0-9]+:/ {
        n=$1; gsub(/[^0-9]/, "", n)
        if (n+0 < 300 && n+0 >= max) max=n+0
      }
      END { print max+0 }
    ' "$work")
    [ "$last" -gt 0 ] || die "Spec has no PatchN"
    new=$((last + 1))
    sed -i "/^Patch${last}:/a Patch${new}: ${base}" "$work"
    if grep -q "^%patch -P${last} " "$work"; then
      apply=$(grep -n "^%patch -P${last} " "$work" | head -1 | cut -d: -f1)
      sed -i "${apply}a %patch -P${new} -p1 -b .progressoff" "$work"
    elif grep -q "^%patch${last} " "$work"; then
      apply=$(grep -n "^%patch${last} " "$work" | head -1 | cut -d: -f1)
      sed -i "${apply}a %patch${new} -p1 -b .progressoff" "$work"
    else
      die "Did not find where Patch${last} is applied"
    fi
    if grep -q '%global _sysconfdir /etc/opt' "$work"; then
      die "Spec moves config under /etc/opt. This Remi EL8 build needs /etc/php.ini"
    fi
    awk '
      /^%changelog$/ && !noted {
        print
        print "* Fri Oct 24 2026 Local rebuild - '"$VERSION-$RELNUM"'"
        print "- Force the upload-progress callback off; official '"$VERSION"' still stores the filename"
        print ""
        noted = 1
        next
      }
      { print }
    ' "$work" > "$work.new"
    mv "$work.new" "$work"
  fi
  printf '%s\n' "$work"
}

opts=(--without tests --define 'debug_package %{nil}' --define "_topdir $TOP")
if [ -n "$DIST" ]; then
  opts+=(--define "dist $DIST")
fi

if [ "$MODE" = --build ]; then
  dnf install -y dnf-plugins-core rpm-build gcc gcc-c++ make cpio curl patch
  dnf config-manager --set-enabled remi >/dev/null
  dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
    || dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 || true
  rm -rf "$TOP"
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  if [ -f "$HERE/$SRPM_NAME" ]; then
    cp -a "$HERE/$SRPM_NAME" "$TOP/$SRPM_NAME"
  else
    curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
  fi
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm)
  mv "$TOP/SOURCES/"*.spec "$TOP/SPECS/php.spec"
  cp -a "$PATCH" "$TOP/SOURCES/$(basename "$PATCH")"
  SPEC=$(prepare_spec "$TOP/SPECS/php.spec" 0)
  mv "$SPEC" "$TOP/SPECS/php.spec"
  SPEC=$TOP/SPECS/php.spec
  if rpm -q libicu69-devel >/dev/null 2>&1 && grep -q 'icu-i18n) >= 74' "$SPEC"; then
    dnf install -y --allowerasing libicu74-devel
  fi
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
