#!/bin/bash
# CentOS 7 x86_64, Remi SCL php70. Run --build first. Install separately with --install.
# Config: /etc/opt/remi/php70. State: /var/opt/remi/php70.
# Release 7.0.33-48.el7.remi. The patch targets the Remi tree, not vanilla php.net.
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
[ -f /etc/redhat-release ] && grep -Eq 'release 7([. ]|$)' /etc/redhat-release \
  || die "This script is for EL7 only"
[ "$(uname -m)" = x86_64 ] || die "This script is x86_64 only"

HERE=$(cd "$(dirname "$0")" && pwd)
SCL=php70
VERSION=7.0.33
RELEASE=48.el7.remi
DIST=.el7.remi
SRPM_NAME=php70-php-7.0.33-47.remi.src.rpm
SRPM_URL=https://mirror.speedpartner.de/remi-archive/SRPMS/$SRPM_NAME
PATCH_NAME=php-7.0.33-remi-cve-2026-109618-109619.patch
VERSION_ID=70033
CHECK_SYMBOL=1
CHECK_MULTIPART=1
PATCH=$PATCH_NAME
TOP=/root/php70-el7-build
[ "$HERE" != "$TOP" ] || die "Do not place the script in $TOP: --build wipes that directory"
PHP=/opt/remi/$SCL/root/usr/bin/php
FPM=/opt/remi/$SCL/root/usr/sbin/php-fpm
EXPECTED_CONF=/etc/opt/remi/$SCL
WRONG_CONF=/opt/remi/$SCL/root/etc
RELNUM=${RELEASE%%.*}
FORCE=${PHP70_FORCE:-0}

current=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$SCL-php-common") \
  || die "$SCL-php-common is not installed"
case "$current" in
  $VERSION-*.el7*.x86_64) ;;
  *)
    if [ "$FORCE" != 1 ]; then
      die "Expected Remi $SCL $VERSION for EL7, found: $current"
    fi
    ;;
esac
rpm -q "$SCL-php-cli" "$SCL-php-fpm" >/dev/null || die "CLI and FPM must be installed"
for pkg in "$SCL-php" "$SCL-php-litespeed" "$SCL-php-oci8"; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this update is FPM only, that SAPI needs its own adaptation"
  fi
done

opts=(--define "scl $SCL" --define 'scl_vendor remi'
      --define '_scl_prefix /opt/remi' --define "dist $DIST"
      --define 'runselftest 0' --define 'debug_package %{nil}'
      --define "_topdir $TOP")

prepare_spec() {
  local spec=$1 finish=$2
  local work
  work=$(mktemp "$TOP/SPECS/php.work.XXXXXX.spec")
  if [ "$finish" = 1 ]; then
    awk '$0 == "%prep" || $0 == "%build" { print; print "exit 0"; next } { print }' \
      "$spec" > "$work"
  else
    cp -a "$spec" "$work"
  fi
  sed -i "0,/^Release:/s/^Release:.*/Release: ${RELNUM}%{?dist}/" "$work"
  if [ -n "$PATCH" ]; then
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
      sed -i "${apply}a %patch${new} -p1 -b .cve109618" "$work"
    elif grep -q "^%patch${last} " "$work"; then
      apply=$(grep -n "^%patch${last} " "$work" | head -1 | cut -d: -f1)
      sed -i "${apply}a %patch${new} -p1 -b .cve109618" "$work"
    else
      die "Did not find where Patch${last} is applied"
    fi
  fi
  sed -i 's/^%patch -P\([0-9][0-9]*\)/%patch\1/' "$work"
  if grep -q '%patch -P' "$work"; then
    die "Spec still has %patch -P, CentOS 7 rpm will not build it"
  fi
  awk '
    $0 == "%scl_package php" && !paths {
      print
      print "%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}"
      print "%global _localstatedir /var/opt/%{scl_vendor}/%{scl}"
      paths = 1
      next
    }
    /^%changelog$/ && !noted {
      print
      print "* Fri Oct 23 2026 Local rebuild - '"$VERSION-$RELNUM"'"
      print "- CVE-2026-109618 and CVE-2026-109619"
      print "- Remi paths /etc/opt/remi/'"$SCL"' and /var/opt/remi/'"$SCL"'"
      print ""
      noted = 1
      next
    }
    { print }
  ' "$work" > "$work.new"
  mv "$work.new" "$work"
  grep -q "^Release: ${RELNUM}%{?dist}$" "$work"
  grep -q '^%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}$' "$work"
  grep -q '^%global _localstatedir /var/opt/%{scl_vendor}/%{scl}$' "$work"
  printf '%s\n' "$work"
}

if [ "$MODE" = --build ]; then
  if [ -n "$PATCH" ]; then
    [ -f "$HERE/$PATCH" ] || die "Missing patch $HERE/$PATCH"
  fi
  for conf in /etc/yum.conf /etc/dnf/dnf.conf; do
    [ -f "$conf" ] || continue
    proxy=$(awk -F= '/^[[:space:]]*proxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
    if [ -n "${proxy:-}" ]; then
      export http_proxy="$proxy" https_proxy="$proxy"
      break
    fi
  done
  yum install -y yum-utils rpm-build scl-utils-build gcc gcc-c++ make cpio curl patch
  if [ -f /etc/yum.repos.d/remi.repo ]; then
    yum-config-manager --enable remi >/dev/null
  fi
  rm -rf "$TOP"
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  if [ -f "$HERE/$SRPM_NAME" ]; then
    cp -a "$HERE/$SRPM_NAME" "$TOP/$SRPM_NAME"
  else
    curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
  fi
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm)
  mv "$TOP/SOURCES/php.spec" "$TOP/SPECS/php.spec"
  if [ -n "$PATCH" ]; then
    cp -a "$HERE/$PATCH" "$TOP/SOURCES/$(basename "$PATCH")"
  fi
  SPEC=$(prepare_spec "$TOP/SPECS/php.spec" 0)
  mv "$SPEC" "$TOP/SPECS/php.spec"
  SPEC=$TOP/SPECS/php.spec
  echo "== dependencies =="
  rpmbuild -bs "${opts[@]}" "$SPEC"
  yum-builddep -y "$TOP"/SRPMS/${SCL}-php-"$VERSION"-*.src.rpm
  echo "== build =="
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

[ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = "$VERSION-$RELEASE" ] \
  || die "No successful build of $VERSION-$RELEASE. Run --build first"
(cd "$TOP" && sha256sum -c RPMS.sha256)

declare -A built=()
while IFS= read -r -d '' f; do
  read -r name ver rel arch < <(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' "$f")
  [ "$ver-$rel" = "$VERSION-$RELEASE" ] || die "Unexpected RPM version: $f"
  case "$arch" in x86_64|noarch) ;; *) die "Unexpected architecture: $f" ;; esac
  case "$name" in ${SCL}-php*) ;; *) die "Unexpected package: $name" ;; esac
  [ -z "${built[$name]:-}" ] || die "Duplicate package: $name"
  built["$name"]=$f
done < <(find "$TOP/RPMS" -type f -name '*.rpm' -print0)

to_install=()
while read -r name source; do
  if [ -n "${built[$name]:-}" ]; then
    to_install+=("${built[$name]}")
  else
    case "$source" in
      ${SCL}-php-${VERSION%%.*}.*) die "Installed package $name has nothing to replace it" ;;
      *) echo "Leaving external package: $name" ;;
    esac
  fi
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' "${SCL}-php*" | sort)
[ "${#to_install[@]}" -gt 0 ] || die "Nothing to install"

common_rpm=${built[${SCL}-php-common]:-}
[ -n "$common_rpm" ] || die "${SCL}-php-common was not built"
new_ini=$(rpm -qpl "$common_rpm" | grep -E '/php\.ini$' || true)
[ -n "$new_ini" ] || die "Built php-common has no php.ini"
[ "$(dirname "$new_ini")" = "$EXPECTED_CONF" ] \
  || die "New php.ini is $new_ini, need $EXPECTED_CONF/php.ini"

rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' "${SCL}*" | sort > "$backup/packages.txt"
conf=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
case "$conf" in
  "$EXPECTED_CONF")
    [ -d "$conf" ] || die "Config directory does not exist: $conf"
    ;;
  "$WRONG_CONF")
    echo "PHP currently reads $conf. These packages restore $EXPECTED_CONF."
    ;;
  *)
    die "PHP reads ${conf:-empty}, expected $EXPECTED_CONF"
    ;;
esac
if [ -d "$EXPECTED_CONF" ]; then
  tar -C / -czf "$backup/config.tar.gz" "${EXPECTED_CONF#/}"
fi
if [ "$conf" = "$WRONG_CONF" ] && [ -d "$WRONG_CONF" ]; then
  tar -C / -czf "$backup/scl-config.tar.gz" "${WRONG_CONF#/}"
fi
"$PHP" -m > "$backup/modules.txt"
rpm -Uvh "${to_install[@]}"
"$PHP" -n -r "if (PHP_VERSION_ID !== $VERSION_ID) { exit(1); } echo PHP_VERSION, \"\\n\";"
now=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
[ "$now" = "$EXPECTED_CONF" ] || die "PHP still reads ${now:-empty}"
if [ "$CHECK_MULTIPART" = 1 ]; then
  "$PHP" -n -r 'if (ini_get("max_multipart_body_parts") !== "-1") exit(1);'
fi
"$PHP" -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 \
  -m > "$backup/modules-after.txt" 2> "$backup/modules-after.err"
if [ -s "$backup/modules-after.err" ]; then
  cat "$backup/modules-after.err" >&2
  die "PHP prints diagnostics at startup. Packages are already updated; check extensions before restarting FPM"
fi
if [ "$CHECK_SYMBOL" = 1 ]; then
  nm -D "$PHP" > "$TOP/nm.txt"
  grep -q ' zend_mm_safe_error_ex$' "$TOP/nm.txt" \
    || die "zend_mm_safe_error_ex is missing from $PHP"
fi
"$FPM" -t
systemctl restart "${SCL}-php-fpm"
systemctl is-active --quiet "${SCL}-php-fpm"
pid=$(systemctl show "${SCL}-php-fpm" -p MainPID | cut -d= -f2)
[[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -e "/proc/$pid/exe" ] || die "FPM master is not running"
cmp -s "$FPM" "/proc/$pid/exe" || die "Running FPM does not match the installed binary"
echo "FPM restarted with PHP $VERSION. Config archive: $backup"
if [ -f "$EXPECTED_CONF/php-fpm.d/www.conf" ]; then
  grep -E '^[[:space:]]*listen[[:space:]]*=' "$EXPECTED_CONF/php-fpm.d/www.conf" || true
fi
echo "Check nginx fastcgi_pass against this pool listen address."
