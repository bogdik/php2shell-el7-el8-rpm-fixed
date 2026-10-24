#!/bin/bash
# CentOS 7 x86_64, Remi SCL php72. Run --build first. Install separately with --install.
# Config: /etc/opt/remi/php72. State: /var/opt/remi/php72.
# Release 7.2.34-31. Next to the script: php-7.2.34-remi-cve-2026-109618-109619.patch
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
TOP=/root/php72-el7-build
VERSION=7.2.34
RELEASE=31.el7.remi
PATCH_NAME=php-7.2.34-remi-cve-2026-109618-109619.patch
SRPM_NAME=php72-php-7.2.34-29.remi.src.rpm
SRPM_URL=https://mirror.speedpartner.de/remi-archive/SRPMS/$SRPM_NAME
PHP=/opt/remi/php72/root/usr/bin/php
FPM=/opt/remi/php72/root/usr/sbin/php-fpm
EXPECTED_CONF=/etc/opt/remi/php72
WRONG_CONF=/opt/remi/php72/root/etc
[ "$HERE" != "$TOP" ] || die "Do not place the script in $TOP: --build wipes that directory"

current=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' php72-php-common) \
  || die "php72-php-common is not installed"
case "$current" in
  7.2.34-*.el7*.x86_64) ;;
  *)
    if [ "${PHP72_FORCE:-0}" != 1 ]; then
      die "Expected Remi php72 7.2.34 for EL7, found: $current"
    fi
    ;;
esac
rpm -q php72-php-cli php72-php-fpm >/dev/null || die "CLI and FPM must be installed"
for pkg in php72-php php72-php-litespeed php72-php-oci8; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    die "$pkg is installed; this update is FPM only, that SAPI needs its own adaptation"
  fi
done

if [ "$MODE" = --build ]; then
  [ -f "$HERE/$PATCH_NAME" ] || die "Missing patch file: $HERE/$PATCH_NAME"
  for conf in /etc/yum.conf /etc/dnf/dnf.conf; do
    [ -f "$conf" ] || continue
    proxy=$(awk -F= '/^[[:space:]]*proxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
    puser=$(awk -F= '/^[[:space:]]*proxy_username[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
    ppass=$(awk -F= '/^[[:space:]]*proxy_password[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" || true)
    if [ -n "${proxy:-}" ]; then
      if [ -n "${puser:-}" ]; then
        proxy=$(printf '%s' "$proxy" | sed "s#://#://${puser}:${ppass}@#")
      fi
      export http_proxy="$proxy" https_proxy="$proxy"
      break
    fi
  done

  yum install -y yum-utils rpm-build scl-utils-build gcc gcc-c++ make cpio curl patch
  if [ -f /etc/yum.repos.d/remi.repo ]; then
    yum-config-manager --enable remi >/dev/null
  fi

  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  cp -a "$HERE/$PATCH_NAME" "$STAGE/$PATCH_NAME"
  if [ -f "$HERE/$SRPM_NAME" ]; then
    cp -a "$HERE/$SRPM_NAME" "$STAGE/$SRPM_NAME"
  fi
  rm -rf "$TOP"
  mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  if [ -f "$STAGE/$SRPM_NAME" ]; then
    cp -a "$STAGE/$SRPM_NAME" "$TOP/$SRPM_NAME"
  else
    curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
  fi
  (cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm)
  mv "$TOP/SOURCES/php.spec" "$TOP/SPECS/php.spec"
  cp -a "$STAGE/$PATCH_NAME" "$TOP/SOURCES/$PATCH_NAME"
  SPEC=$TOP/SPECS/php.spec

  echo "== spec =="
  sed -i '0,/^Release:/s/^Release:.*/Release: 31%{?dist}/' "$SPEC"
  sed -i "/^Patch240: php-cve-2026-7260.patch$/a Patch241: $PATCH_NAME" "$SPEC"
  # rpm 4.11 accepts only %patchN. The insert happens before %patch -P is rewritten.
  sed -i '/^%patch -P240 -p1 -b .cve7260$/a %patch241 -p1 -b .cve109618' "$SPEC"
  sed -i 's/^%patch -P\([0-9][0-9]*\)/%patch\1/' "$SPEC"
  if grep -q '%patch -P' "$SPEC"; then
    die "Spec still has %patch -P, CentOS 7 rpm will not build it"
  fi
  awk '
    $0 == "%scl_package php" && !paths {
      print
      print "# Remi keeps config and state outside the SCL root."
      print "# %scl_package sets the stock SCL paths; a later %global replaces them."
      print "%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}"
      print "%global _localstatedir /var/opt/%{scl_vendor}/%{scl}"
      paths = 1
      next
    }
    /^%changelog$/ && !noted {
      print
      print "* Fri Oct 23 2026 Local rebuild - 7.2.34-31"
      print "- mitigation for CVE-2026-109618 and CVE-2026-109619"
      print "- Remi paths /etc/opt/remi/php72 and /var/opt/remi/php72"
      print ""
      noted = 1
      next
    }
    { print }
  ' "$SPEC" > "$SPEC.new"
  mv "$SPEC.new" "$SPEC"
  grep -q '^Release: 31%{?dist}$' "$SPEC"
  grep -q "^Patch241: $PATCH_NAME$" "$SPEC"
  grep -q '^%patch241 -p1 -b .cve109618$' "$SPEC"
  grep -q '^%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}$' "$SPEC"
  grep -q '^%global _localstatedir /var/opt/%{scl_vendor}/%{scl}$' "$SPEC"

  opts=(--define 'scl php72' --define 'scl_vendor remi'
        --define '_scl_prefix /opt/remi' --define 'dist .el7.remi'
        --define "runselftest 0" --define 'debug_package %{nil}'
        --define "_topdir $TOP")
  echo "== dependencies =="
  rpmbuild -bs "${opts[@]}" "$SPEC"
  yum-builddep -y "$TOP"/SRPMS/php72-php-"$VERSION"-*.src.rpm
  echo "== build =="
  rpmbuild -ba "${opts[@]}" "$SPEC" 2>&1 | tee "$TOP/build.log"

  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || die "RPMs were not built"
  printf '%s-%s\n' "$VERSION" "$RELEASE" > "$TOP/BUILD-OK"
  echo "Build ready. RPMs: $TOP/RPMS"
  echo "Install separately: bash $HERE/build-php72-el7.sh --install"
  exit 0
fi

if [ "$MODE" = --finish ]; then
  # --short-circuit marks packages rpmlib(ShortCircuited); they must not be installed.
  # A normal -bb: %prep and %build return immediately and the build tree stays.
  [ -x "$TOP/BUILD/php-$VERSION/build-fpm/sapi/fpm/php-fpm" ] \
    || die "Built FPM is not in $TOP/BUILD. Need a full --build; do not delete the build directory"
  installed_fpm=$(find "$TOP/BUILDROOT" -type f -name php-fpm -print -quit)
  [ -n "$installed_fpm" ] || die "BUILDROOT has no php-fpm, %install did not finish"
  [ -f "$TOP/SPECS/php.spec" ] || die "Missing $TOP/SPECS/php.spec"
  rm -f "$TOP/BUILD-OK" "$TOP/RPMS.sha256"
  find "$TOP/RPMS" -type f -name '*.rpm' -delete
  finish_spec=$(mktemp "$TOP/SPECS/php.finish.XXXXXX.spec")
  awk '
    $0 == "%prep" || $0 == "%build" { print; print "exit 0"; next }
    { print }
  ' "$TOP/SPECS/php.spec" > "$finish_spec"
  opts=(--define 'scl php72' --define 'scl_vendor remi'
        --define '_scl_prefix /opt/remi' --define 'dist .el7.remi'
        --define "runselftest 0" --define 'debug_package %{nil}'
        --define "_topdir $TOP")
  rpmbuild -bb --nocheck --noclean "${opts[@]}" "$finish_spec" \
    2>&1 | tee -a "$TOP/build.log"
  rm -f "$finish_spec"
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
  echo "Install separately: bash $HERE/build-php72-el7.sh --install"
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
  case "$name" in php72-php*) ;; *) die "Unexpected package: $name" ;; esac
  [ -z "${built[$name]:-}" ] || die "Duplicate package: $name"
  built["$name"]=$f
done < <(find "$TOP/RPMS" -type f -name '*.rpm' -print0)

to_install=()
while read -r name source; do
  if [ -n "${built[$name]:-}" ]; then
    to_install+=("${built[$name]}")
  else
    case "$source" in
      php72-php-7.2.*) die "Installed package $name has nothing to replace it" ;;
      *) echo "Leaving external package: $name" ;;
    esac
  fi
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' 'php72-php*' | sort)
[ "${#to_install[@]}" -gt 0 ] || die "Nothing to install"

common_rpm=${built[php72-php-common]:-}
[ -n "$common_rpm" ] || die "php72-php-common was not built"
new_ini=$(rpm -qpl "$common_rpm" | grep -E '/php\.ini$' || true)
[ -n "$new_ini" ] || die "Built php-common has no php.ini"
[ "$(dirname "$new_ini")" = "$EXPECTED_CONF" ] \
  || die "New php.ini is $new_ini, need $EXPECTED_CONF/php.ini"

rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 'php72*' | sort > "$backup/packages.txt"
conf=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
case "$conf" in
  "$EXPECTED_CONF")
    [ -d "$conf" ] || die "Config directory does not exist: $conf"
    ;;
  "$WRONG_CONF")
    echo "PHP currently reads $conf. These packages restore $EXPECTED_CONF."
    echo "Edits already made in $conf are not copied over. They stay in the archive."
    ;;
  *)
    die "PHP reads ${conf:-empty}, expected $EXPECTED_CONF"
    ;;
esac
tar_dir() {
  local dir=$1 name=$2
  if [ -d "$dir" ]; then
    tar -C / -czf "$backup/$name.tar.gz" "${dir#/}"
  fi
}
tar_dir "$EXPECTED_CONF" config
if [ "$conf" = "$WRONG_CONF" ]; then
  tar_dir "$WRONG_CONF" scl-config
  if [ -d "$EXPECTED_CONF" ]; then
    while IFS= read -r -d '' save; do
      dest=${save%.rpmsave}
      if [ ! -e "$dest" ]; then
        cp -a "$save" "$dest"
        echo "Restored $dest from rpmsave"
      fi
    done < <(find "$EXPECTED_CONF" -name '*.rpmsave' -print0)
  fi
fi
"$PHP" -m > "$backup/modules.txt"

rpm -Uvh "${to_install[@]}"
"$PHP" -n -r 'if (PHP_VERSION_ID !== 70234) { exit(1); } echo PHP_VERSION, "\n";'
now=$("$PHP" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
[ "$now" = "$EXPECTED_CONF" ] || die "PHP still reads ${now:-empty}"
"$PHP" -n -r 'if (ini_get("max_multipart_body_parts") !== "-1") exit(1);'
"$PHP" -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 \
  -m > "$backup/modules-after.txt" 2> "$backup/modules-after.err"
if [ -s "$backup/modules-after.err" ]; then
  cat "$backup/modules-after.err" >&2
  die "PHP prints diagnostics at startup. Packages are already updated; check extensions before restarting FPM"
fi
diff -u "$backup/modules.txt" "$backup/modules-after.txt" || true
nm -D "$PHP" > "$TOP/nm.txt"
grep -q ' zend_mm_safe_error_ex$' "$TOP/nm.txt" \
  || die "zend_mm_safe_error_ex is missing from $PHP"
"$FPM" -t
systemctl restart php72-php-fpm
systemctl is-active --quiet php72-php-fpm
pid=$(systemctl show php72-php-fpm -p MainPID | cut -d= -f2)
[[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -e "/proc/$pid/exe" ] || die "FPM master is not running"
cmp -s "$FPM" "/proc/$pid/exe" || die "Running FPM does not match the installed binary"
rpm -q php72-php-common php72-php-cli php72-php-fpm
echo "FPM restarted with PHP $VERSION. Config archive: $backup ($EXPECTED_CONF)"
if [ -f "$EXPECTED_CONF/php-fpm.d/www.conf" ]; then
  grep -E '^[[:space:]]*listen[[:space:]]*=' "$EXPECTED_CONF/php-fpm.d/www.conf" || true
fi
echo "Check nginx fastcgi_pass against this pool listen address."
