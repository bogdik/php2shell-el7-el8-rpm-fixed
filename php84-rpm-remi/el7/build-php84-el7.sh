#!/bin/bash
# CentOS 7 x86_64, Remi SCL php84. Run --build first. Install separately with --install.
# Config: /etc/opt/remi/php84. State: /var/opt/remi/php84.
# Base: the system SRPM php-8.4.27-1.remi.src.rpm from EL8. EL7 has no SCL of its own.
# rpm 4.11 does not understand Recommends or %patch -P: adapt-spec.py rewrites the spec.
# System OpenSSL is 1.0.2. The build uses openssl11 1.1.1 and devtoolset-11.
# Official 8.4.27 does not disable upload progress. The patch silences the callback.
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
SCL=php84
VERSION=8.4.27
RELEASE=3.el7.remi.local
DIST=.el7.remi.local
SRPM_NAME=php-8.4.27-1.remi.src.rpm
SRPM_URL=https://rpms.remirepo.net/SRPMS/$SRPM_NAME
PROGRESS_PATCH=php-8.4.27-upload-progress-off.patch
FFI_PATCH=php-8.4.27-ffi-strncmp.patch
VERSION_ID=80427
CHECK_SYMBOL=0
CHECK_MULTIPART=0
TOP=/root/php84-el7-build
[ "$HERE" != "$TOP" ] || die "Do not place the script in $TOP: --build wipes that directory"
PHP=/opt/remi/$SCL/root/usr/bin/php
FPM=/opt/remi/$SCL/root/usr/sbin/php-fpm
EXPECTED_CONF=/etc/opt/remi/$SCL
WRONG_CONF=/opt/remi/$SCL/root/etc
RELNUM=${RELEASE%%.*}

for pkg in "$SCL-php" "$SCL-php-litespeed" "$SCL-php-oci8"; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this update is FPM only"
  fi
done

opts=(--define "scl $SCL" --define 'scl_vendor remi'
      --define '_scl_prefix /opt/remi' --define "dist $DIST"
      --without tests --without libxcrypt --without lsws --without firebird --without qdbm --without libpcre
      --define "_topdir $TOP")

prepare_spec() {
  local spec=$1 finish=$2
  local work
  work=$(mktemp "$TOP/SPECS/php.work.XXXXXX.spec")
  if [ "$finish" = 1 ]; then
    awk '$0 == "%prep" || $0 == "%build" { print; print "exit 0"; next } { print }' \
      "$spec" > "$work"
  else
    python3 "$HERE/adapt-spec.py" "$spec" "$work"
    sed -i "0,/^Release:/s/^Release:.*/Release: ${RELNUM}%{?dist}/" "$work"
    sed -i \
      -e 's/pkgconfig(icu-i18n) >= 74/pkgconfig(icu-i18n) >= 73/' \
      -e 's/pkgconfig(icu-io)   >= 74/pkgconfig(icu-io)   >= 73/' \
      -e 's/pkgconfig(icu-uc)   >= 74/pkgconfig(icu-uc)   >= 73/' \
      "$work"
    sed -i 's/^rm /rm -f /' "$work"
    if ! rpm -q nginx-filesystem >/dev/null 2>&1 \
        && ! yum -q list nginx-filesystem >/dev/null 2>&1; then
      sed -i '/^BuildRequires:[[:space:]]*nginx-filesystem/d' "$work"
    fi
    # EL7 httpd owns those directories and unixODBC has no odbc.pc.
    sed -i \
      -e '/^BuildRequires:[[:space:]]*httpd-filesystem[[:space:]]*$/d' \
      -e 's/^Requires(pre):[[:space:]]*httpd-filesystem[[:space:]]*$/Requires(pre): httpd/' \
      -e 's/^Requires:[[:space:]]*httpd-filesystem >= 2.4.10/Requires: httpd >= 2.4.6/' \
      -e 's/^BuildRequires:[[:space:]]*pkgconfig(odbc)[[:space:]]*$/BuildRequires: unixODBC-devel/' \
      "$work"
    # SCL %{_prefix} is /opt/remi/phpXX/root/usr. System libraries live in /usr,
    # and the private libpq is in /opt/php-el7-libs.
    sed -i \
      -e 's|--with-db4=%{_prefix}|--with-db4=/usr|' \
      -e 's|--with-tcadb=%{_prefix}|--with-tcadb=/usr|' \
      -e 's|--with-lmdb=%{_prefix}|--with-lmdb=/usr|' \
      -e 's|--with-snmp=shared,%{_prefix}|--with-snmp=shared,/usr|' \
      -e 's|--with-xsl=shared,%{_prefix}|--with-xsl=shared,/usr|' \
      -e 's|--with-pdo-dblib=shared,%{_prefix}|--with-pdo-dblib=shared,/usr|' \
      -e 's|--with-tidy=shared,%{_prefix}|--with-tidy=shared,/usr|' \
      -e 's|--with-pdo-pgsql=shared,%{_prefix}|--with-pdo-pgsql=shared,/opt/php-el7-libs|' \
      "$work"
    local patch base last new apply
    for patch in "$PROGRESS_PATCH" "$FFI_PATCH"; do
      base=$(basename "$patch")
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
        sed -i "${apply}a %patch${new} -p1 -b .extra${new}" "$work"
      elif grep -q "^%patch${last} " "$work"; then
        apply=$(grep -n "^%patch${last} " "$work" | head -1 | cut -d: -f1)
        sed -i "${apply}a %patch${new} -p1 -b .extra${new}" "$work"
      else
        die "Did not find where Patch${last} is applied"
      fi
    done
    sed -i 's/^%patch -P\([0-9][0-9]*\)/%patch\1/' "$work"
    if grep -q '%patch -P' "$work"; then
      die "Spec still has %patch -P, CentOS 7 rpm will not build it"
    fi
    if grep -q '^Recommends:' "$work"; then
      die "Spec still has Recommends, CentOS 7 rpm will not read it"
    fi
    python3 - "$work" "$SCL" "${VERSION%.*}-${RELNUM}.el7.remi.local" << 'PY'
import pathlib, sys
path, scl, evr = sys.argv[1:]
file = pathlib.Path(path)
text = file.read_text()
needle = "%package common\n"
extra = (
    needle
    + f"Requires: {scl}-runtime = {evr}\n"
    + "Requires: php-el7-libs = 1.0-1.el7.local\n"
    + "Requires: openssl11-libs\n"
)
if f"Requires: {scl}-runtime = {evr}\n" not in text:
    if needle not in text:
        raise SystemExit("spec has no %package common")
    text = text.replace(needle, extra, 1)
file.write_text(text)
PY
    if ! grep -q 'export LDFLAGS=.*php-el7-libs/lib' "$work"; then
      sed -i '/^build() {/a export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,/opt/php-el7-libs/lib -Wl,-rpath,/usr/lib64/openssl11"' "$work"
    fi
    grep -q '^%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}$' "$work"
    grep -q '^%global _localstatedir /var/opt/%{scl_vendor}/%{scl}$' "$work"
    awk '
      /^%changelog$/ && !noted {
        print
        print "* Fri Oct 24 2026 Local rebuild - '"$VERSION-$RELNUM"'"
        print "- EL7 SCL backport of the EL8 Remi module"
        print "- Force the upload-progress callback off"
        print "- Remi paths /etc/opt/remi/'"$SCL"' and /var/opt/remi/'"$SCL"'"
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

stage_support_rpms() {
  bash "$HERE/el7-libs.sh"
  mkdir -p "$TOP/RPMS/x86_64"
  cp -a /root/php-el7-libs-build/RPMS/x86_64/php-el7-libs-1.0-1.el7.local.x86_64.rpm \
        /root/php-el7-libs-build/RPMS/x86_64/php-el7-libs-devel-1.0-1.el7.local.x86_64.rpm \
        "$TOP/RPMS/x86_64/"
  rpmbuild -bb --define "_topdir $TOP" "$HERE/runtime.spec"
  {
    echo "=== enabled repos ==="
    yum repolist -v
    echo "=== installed packages ==="
    rpm -qa | sort
  } > "$TOP/build-environment.txt"
}

hash_rpms() {
  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "RPMs were not built"
}

if [ "$MODE" = --build ]; then
  [ -f "$HERE/$PROGRESS_PATCH" ] || die "Missing patch $HERE/$PROGRESS_PATCH"
  [ -f "$HERE/$FFI_PATCH" ] || die "Missing patch $HERE/$FFI_PATCH"
  [ -f "$HERE/adapt-spec.py" ] || die "Missing $HERE/adapt-spec.py"
  for conf in /etc/yum.conf /etc/dnf/dnf.conf; do
    [ -f "$conf" ] || continue
    proxy=$(awk -F= '/^[[:space:]]*proxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
    if [ -n "${proxy:-}" ]; then
      export http_proxy="$proxy" https_proxy="$proxy"
      break
    fi
  done
  yum install -y yum-utils rpm-build scl-utils-build gcc gcc-c++ make cpio curl patch \
    openssl11-devel devtoolset-11-gcc devtoolset-11-gcc-c++ redhat-rpm-config python36
  if ! command -v python3 >/dev/null 2>&1; then
    ln -sf /usr/bin/python36 /usr/bin/python3
  fi
  if [ -f /etc/yum.repos.d/remi.repo ]; then
    yum-config-manager --enable remi >/dev/null
  fi
  if [ ! -f /usr/lib64/pkgconfig/odbc.pc ]; then
    cat > /usr/lib64/pkgconfig/odbc.pc << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib64
includedir=${prefix}/include

Name: odbc
Description: unixODBC
Version: 2.3.1
Libs: -L${libdir} -lodbc
Cflags: -I${includedir}
EOF
  fi
  mkdir -p /opt/php-openssl11/pkgconfig
  cat > /opt/php-openssl11/pkgconfig/openssl.pc << 'EOF'
prefix=/usr
libdir=${prefix}/lib64/openssl11
includedir=${prefix}/include/openssl11

Name: OpenSSL
Description: OpenSSL 1.1.1 for the EL7 PHP backport
Version: 1.1.1k
Libs: -L${libdir} -lssl -lcrypto -Wl,-rpath,/usr/lib64/openssl11 -Wl,-rpath,/opt/php-el7-libs/lib
Cflags: -I${includedir}
EOF
  avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "${avail_gb:-0}" -ge 12 ] || die "Need at least 12 GiB free on /, found ${avail_gb:-0}"
  bash "$HERE/el7-libs.sh" --install
  rm -rf "$TOP"
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  if [ -f "$HERE/$SRPM_NAME" ]; then
    cp -a "$HERE/$SRPM_NAME" "$TOP/$SRPM_NAME"
  else
    curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
  fi
  libs_root=$HERE/../../php-el7-libs
  if gpg --version 2>/dev/null | head -1 | grep -Eq '2\.([2-9]|[1-9][0-9])'; then
    bash "$libs_root/verify-srpm.sh" "$TOP/$SRPM_NAME"
  else
    stamp=$HERE/$SRPM_NAME.sigok
    [ -f "$stamp" ] || die "No signature stamp for $SRPM_NAME. Run bash $libs_root/verify-srpm.sh on a host with GnuPG >= 2.2."
    read -r stamp_hash stamp_fpr < "$stamp"
    [ "$stamp_fpr" = "2E375FE24EDFF0F2E0D8E165ED5B58C5BEFA00E2" ] || die "Unexpected Remi fingerprint in $stamp"
    got=$(sha256sum "$TOP/$SRPM_NAME" | awk '{print $1}')
    [ "$got" = "$stamp_hash" ] || die "$SRPM_NAME does not match the verified signature stamp"
    pinned=$(awk -v n="$SRPM_NAME" '$1 !~ /^#/ && $2 == n { print $1 }' "$libs_root/SOURCES.sha256")
    [ "$got" = "$pinned" ] || die "$SRPM_NAME does not match SOURCES.sha256"
    echo "SRPM digest matches the ed25519 verification stamp"
  fi
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm)
  mv "$TOP/SOURCES/"*.spec "$TOP/SPECS/php.spec"
  cp -a "$HERE/$PROGRESS_PATCH" "$TOP/SOURCES/$(basename "$PROGRESS_PATCH")"
  cp -a "$HERE/$FFI_PATCH" "$TOP/SOURCES/$(basename "$FFI_PATCH")"
  SPEC=$(prepare_spec "$TOP/SPECS/php.spec" 0)
  mv "$SPEC" "$TOP/SPECS/php.spec"
  SPEC=$TOP/SPECS/php.spec
  echo "== dependencies =="
  rpmbuild -bs "${opts[@]}" "$SPEC"
  yum-builddep -y "$TOP"/SRPMS/${SCL}-php-"$VERSION"-*.src.rpm
  echo "== build =="
  # shellcheck disable=SC1091
  . /opt/rh/devtoolset-11/enable
  rpmbuild -ba "${opts[@]}" "$SPEC" 2>&1 | tee "$TOP/build.log"
  stage_support_rpms
  hash_rpms
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
  # shellcheck disable=SC1091
  . /opt/rh/devtoolset-11/enable
  rpmbuild -bb --nocheck --noclean "${opts[@]}" "$SPEC" 2>&1 | tee -a "$TOP/build.log"
  rm -f "$SPEC"
  if find "$TOP/RPMS" -type f -name '*.rpm' -print0 \
      | xargs -0 -r rpm -qp --requires \
      | grep -q 'rpmlib(ShortCircuited)'; then
    die "RPMs are marked ShortCircuited and must not be installed"
  fi
  stage_support_rpms
  hash_rpms
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Packaged the build that was already there. RPMs: $TOP/RPMS"
  exit 0
fi

[ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = "$VERSION-$RELEASE" ] \
  || die "No successful build of $VERSION-$RELEASE. Run --build first"
(cd "$TOP" && sha256sum -c RPMS.sha256)

declare -A built=()
runtime_rpm=
libs_rpm=
while IFS= read -r -d '' f; do
  read -r name ver rel arch < <(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' "$f")
  case "$arch" in x86_64|noarch) ;; *) die "Unexpected architecture: $f" ;; esac
  case "$name" in
    ${SCL}-php*)
      [ "$ver-$rel" = "$VERSION-$RELEASE" ] || die "Unexpected RPM version: $f"
      [ -z "${built[$name]:-}" ] || die "Duplicate package: $name"
      built["$name"]=$f
      ;;
    ${SCL}-runtime)
      [ "$ver-$rel" = "${VERSION%.*}-${RELNUM}.el7.remi.local" ] || die "Unexpected runtime: $f"
      runtime_rpm=$f
      ;;
    php-el7-libs)
      [ "$ver-$rel" = "1.0-1.el7.local" ] || die "Unexpected php-el7-libs: $f"
      libs_rpm=$f
      ;;
    php-el7-libs-devel) ;;
    *) die "Unexpected package: $name" ;;
  esac
done < <(find "$TOP/RPMS" -type f -name '*.rpm' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' -print0)
[ -n "$runtime_rpm" ] || die "Missing ${SCL}-runtime"
[ -n "$libs_rpm" ] || die "Missing php-el7-libs"

to_install=()
while read -r name source; do
  [ -n "$name" ] || continue
  if [ -n "${built[$name]:-}" ]; then
    to_install+=("${built[$name]}")
  else
    case "$source" in
      ${SCL}-php-${VERSION%%.*}.*) die "Installed package $name has nothing to replace it" ;;
      *) echo "Leaving external package: $name" ;;
    esac
  fi
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' "${SCL}-php*" | sort)
if [ "${#to_install[@]}" -eq 0 ]; then
  for name in "$SCL-php-common" "$SCL-php-cli" "$SCL-php-fpm"; do
    [ -n "${built[$name]:-}" ] || die "No built $name"
    to_install+=("${built[$name]}")
  done
fi

common_rpm=${built[${SCL}-php-common]:-}
[ -n "$common_rpm" ] || die "${SCL}-php-common was not built"
new_ini=$(rpm -qpl "$common_rpm" | grep -E '/php\.ini$' || true)
[ -n "$new_ini" ] || die "Built php-common has no php.ini"
[ "$(dirname "$new_ini")" = "$EXPECTED_CONF" ] \
  || die "New php.ini is $new_ini, need $EXPECTED_CONF/php.ini"

to_install=("$libs_rpm" "$runtime_rpm" "${to_install[@]}")
rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' "${SCL}*" | sort > "$backup/packages.txt"
if [ -x "$PHP" ]; then
  conf=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
  case "$conf" in
    "$EXPECTED_CONF"|"$WRONG_CONF") ;;
    *) die "PHP reads ${conf:-empty}, expected $EXPECTED_CONF" ;;
  esac
fi
if [ -d "$EXPECTED_CONF" ]; then
  tar -C / -czf "$backup/config.tar.gz" "${EXPECTED_CONF#/}"
fi
rpm -Uvh "${to_install[@]}"
"$PHP" -n -r "if (PHP_VERSION_ID !== $VERSION_ID) { exit(1); } echo PHP_VERSION, \"\\n\";"
now=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
[ "$now" = "$EXPECTED_CONF" ] || die "PHP still reads ${now:-empty}"
"$PHP" -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 -m >/dev/null
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
