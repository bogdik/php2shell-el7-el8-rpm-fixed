#!/bin/bash
# CentOS 7 x86_64, Remi SCL php83. Build first, install in a separate invocation.
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
[ "$(uname -m)" = x86_64 ] || die "This script is for x86_64 only"

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=/root/php83-8.3.36-el7
VERSION=8.3.36
RELEASE=2.el7.remi.local
SRPM=php83-php-8.3.36-1.remi.src.rpm
SRPM_SHA=9fd36fec21041432aca7c9fe08c5714044c3b591a23fcec0a6b3826c8101ee64
SOURCE_SHA=dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd
PHP=/opt/remi/php83/root/usr/bin/php
FPM=/opt/remi/php83/root/usr/sbin/php-fpm
JOBS=${PHP83_JOBS:-2}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "PHP83_JOBS must be a positive integer"

current=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' php83-php-common) \
  || die "php83-php-common is not installed"
case "$current" in 8.3.*.el7*.x86_64) ;; *) die "Expected Remi php83 for EL7; found $current" ;; esac
rpm -q php83-php-cli php83-php-fpm >/dev/null || die "CLI and FPM packages must be installed"
# These SAPIs need their own service validation and restart procedure.
for pkg in php83-php php83-php-litespeed php83-php-oci8; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this FPM-only upgrade needs adaptation for it"
  fi
done

if [ "$MODE" = --build ]; then
  [ -f "$HERE/php83-el7.spec.patch" ] || die "Missing php83-el7.spec.patch next to script"
  [ -f "$HERE/php-8.3.36-ffi-strncmp.patch" ] || die "Missing php-8.3.36-ffi-strncmp.patch next to script"
  [ -f "$HERE/php-8.3.36-openssl-asn1.patch" ] || die "Missing php-8.3.36-openssl-asn1.patch next to script"
  [ -f "$HERE/php-8.3.36-upload-progress-off.patch" ] || die "Missing php-8.3.36-upload-progress-off.patch next to script"
  yum install -y yum-utils rpm-build scl-utils-build cpio curl patch gcc gcc-c++ make
  if [ -f /etc/yum.repos.d/remi.repo ]; then
    yum-config-manager --enable remi
  fi
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  # A failed rebuild must never leave a previous success marker usable.
  rm -f "$TOP/BUILD-OK" "$TOP/RPMS.sha256"
  rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 'php83*' \
    | sort > "$TOP/packages-before-build.txt"

  if [ -f "$HERE/$SRPM" ]; then
    cp "$HERE/$SRPM" "$TOP/$SRPM"
  elif [ ! -f "$TOP/$SRPM" ]; then
    # curl does not read yum.conf. Use HTTPS_PROXY if this host requires a proxy.
    curl -fL --retry 3 --max-time 180 \
      -o "$TOP/$SRPM.part" "https://mirror.speedpartner.de/remi-archive/SRPMS/$SRPM"
    mv "$TOP/$SRPM.part" "$TOP/$SRPM"
  fi
  printf '%s  %s\n' "$SRPM_SHA" "$TOP/$SRPM" | sha256sum -c -
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM" | cpio -idmu --quiet)
  printf '%s  %s\n' "$SOURCE_SHA" "$TOP/SOURCES/php-$VERSION.tar.xz" | sha256sum -c -
  cp "$HERE/php-8.3.36-ffi-strncmp.patch" "$TOP/SOURCES/php-8.3.36-ffi-strncmp.patch"
  cp "$HERE/php-8.3.36-openssl-asn1.patch" "$TOP/SOURCES/php-8.3.36-openssl-asn1.patch"
  cp "$HERE/php-8.3.36-upload-progress-off.patch" "$TOP/SOURCES/php-8.3.36-upload-progress-off.patch"
  cp "$TOP/SOURCES/php.spec" "$TOP/SPECS/php.spec"
  SPEC=$TOP/SPECS/php.spec
  patch --batch --forward --fuzz=0 "$SPEC" "$HERE/php83-el7.spec.patch"
  sed -i '0,/^Release:/s/^Release:.*/Release: 2%{?dist}/' "$SPEC"
  # rpm 4.11 on EL7 only accepts %patchN. Remi's spec uses %patch -P N.
  sed -i 's/^%patch -P\([0-9][0-9]*\)/%patch\1/' "$SPEC"
  if grep -q '%patch -P' "$SPEC"; then
    die "Spec still contains %patch -P; EL7 rpm cannot build it"
  fi

  opts=(--define 'scl php83' --define 'scl_vendor remi'
        --define '_scl_prefix /opt/remi' --define 'dist .el7.remi.local'
        --define "_topdir $TOP" --define "_smp_mflags -j$JOBS"
        --define 'debug_package %{nil}')
  # An uncommon non-PECL zip package must be rebuilt too if installed.
  if rpm -q php83-php-zip >/dev/null 2>&1; then
    opts+=(--define '_with_zip 1')
  fi
  # yum-builddep on EL7 does not accept rpm --define. Expand them into an
  # SRPM header first, then install those BuildRequires.
  rpmbuild -bs "${opts[@]}" "$SPEC"
  yum-builddep -y "$TOP"/SRPMS/php83-php-"$VERSION"-*.src.rpm
  rpmbuild -ba "${opts[@]}" "$SPEC" 2>&1 | tee "$TOP/build.log"

  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "No RPMs produced"
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Build completed. RPMs: $TOP/RPMS"
  echo "Install separately: bash $HERE/build-php83-el7.sh --install"
  exit 0
fi

if [ "$MODE" = --finish ]; then
  # --short-circuit writes rpmlib(ShortCircuited), which rpm refuses to install.
  # Package with a normal -bb instead: %prep and %build return immediately so
  # the compiled tree stays, %install runs again, and --nocheck skips the tests.
  [ -x "$TOP/BUILD/php-$VERSION/build-fpm/sapi/fpm/php-fpm" ] \
    || die "Compiled FPM is missing; run --build"
  installed_fpm=$(find "$TOP/BUILDROOT" -type f -name php-fpm -print -quit)
  [ -n "$installed_fpm" ] || die "BUILDROOT has no php-fpm; %install did not finish"
  [ -f "$TOP/SPECS/php.spec" ] || die "SPECS/php.spec is missing"
  rm -f "$TOP/BUILD-OK" "$TOP/RPMS.sha256"
  find "$TOP/RPMS" -type f -name '*.rpm' -delete
  finish_spec=$(mktemp "$TOP/SPECS/php.finish.XXXXXX.spec")
  awk '
    $0 == "%prep" || $0 == "%build" { print; print "exit 0"; next }
    { print }
  ' "$TOP/SPECS/php.spec" > "$finish_spec"
  opts=(--define 'scl php83' --define 'scl_vendor remi'
        --define '_scl_prefix /opt/remi' --define 'dist .el7.remi.local'
        --define "_topdir $TOP" --define "_smp_mflags -j$JOBS"
        --define 'debug_package %{nil}')
  if rpm -q php83-php-zip >/dev/null 2>&1; then
    opts+=(--define '_with_zip 1')
  fi
  rpmbuild -bb --nocheck --noclean "${opts[@]}" "$finish_spec" \
    2>&1 | tee -a "$TOP/build.log"
  rm -f "$finish_spec"
  if find "$TOP/RPMS" -type f -name '*.rpm' -print0 \
      | xargs -0 -r rpm -qp --requires \
      | grep -q 'rpmlib(ShortCircuited)'; then
    die "RPMs are still marked ShortCircuited and cannot be installed"
  fi
  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "No RPMs produced"
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Packaged the existing build. RPMs: $TOP/RPMS"
  echo "Install separately: bash $HERE/build-php83-el7.sh --install"
  exit 0
fi

[ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = "$VERSION-$RELEASE" ] \
  || die "No successful build; run --build first"
(cd "$TOP" && sha256sum -c RPMS.sha256)

declare -A built=()
while IFS= read -r -d '' f; do
  read -r name ver rel arch < <(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' "$f")
  [ "$ver-$rel" = "$VERSION-$RELEASE" ] || die "Unexpected RPM version: $f"
  case "$arch" in x86_64|noarch) ;; *) die "Unexpected architecture: $f" ;; esac
  case "$name" in php83-php*) ;; *) die "Unexpected package: $name" ;; esac
  [ -z "${built[$name]:-}" ] || die "Duplicate package: $name"
  built["$name"]=$f
done < <(find "$TOP/RPMS" -type f -name '*.rpm' -print0)

to_install=()
while read -r name source; do
  if [ -n "${built[$name]:-}" ]; then
    to_install+=("${built[$name]}")
  else
    case "$source" in
      php83-php-8.3.*) die "Installed core package $name has no replacement RPM" ;;
      *) echo "Keeping external extension/package: $name" ;;
    esac
  fi
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' 'php83-php*' | sort)
[ "${#to_install[@]}" -gt 0 ] || die "No packages selected"

# Check dependency/ABI requirements without changing installed packages.
rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 'php83*' | sort > "$backup/packages.txt"
conf=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
[ -d "$conf" ] || die "PHP config directory does not exist: ${conf:-empty}"
common_rpm=${built[php83-php-common]:-}
[ -n "$common_rpm" ] || die "php83-php-common was not built"
new_ini=$(rpm -qpl "$common_rpm" | grep -E '/php\.ini$' || true)
[ -n "$new_ini" ] || die "Built php-common package has no php.ini"
[ "$(dirname "$new_ini")" = "$conf" ] \
  || die "New php.ini is $new_ini but the installed PHP reads $conf"
tar -C / -czf "$backup/config.tar.gz" "${conf#/}"
"$PHP" -m > "$backup/modules.txt"

rpm -Uvh "${to_install[@]}"
"$PHP" -n -r 'if (PHP_VERSION_ID !== 80336) { exit(1); } echo PHP_VERSION, "\n";'
"$PHP" -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 \
  -m > "$backup/modules-after.txt" 2> "$backup/modules-after.err"
if [ -s "$backup/modules-after.err" ]; then
  cat "$backup/modules-after.err" >&2
  die "PHP reports startup diagnostics. Packages updated; inspect extensions before restarting FPM"
fi
diff -u "$backup/modules.txt" "$backup/modules-after.txt" || true
"$FPM" -t
systemctl restart php83-php-fpm
systemctl is-active --quiet php83-php-fpm
pid=$(systemctl show php83-php-fpm -p MainPID | cut -d= -f2)
[[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -e "/proc/$pid/exe" ] || die "No running FPM master"
cmp -s "$FPM" "/proc/$pid/exe" || die "Running FPM does not match installed binary"
rpm -q php83-php-common php83-php-cli php83-php-fpm
echo "FPM restarted with PHP $VERSION. Configuration backup: $backup/config.tar.gz ($conf)"
echo "Check application responses and nginx fastcgi_pass against this FPM listen address."
