#!/bin/bash
# CentOS Stream 8 / RHEL 8, root.
# Rebuilds the system AppStream php-7.2.24 with the minimal patch
# CVE-2026-109618 and CVE-2026-109619 and installs it over the packages already present
# php-* packages. php.ini and the FPM pool are not overwritten (noreplace).
# php-pecl-zip is left alone: the Zend structure layout did not change.
#
# The script directory must contain
#   php-7.2-cve-2026-109618-109619.patch
# The SRPM is taken from disk when it sits next to the script. Otherwise it is fetched from vault.
# The build takes about an hour. Finished RPMs stay in /root/php72-cve-build/RPMS.
# The script directory is not deleted: the build runs in a separate directory.
# No argument means --build. Install separately with --install. Paths stay at /etc/php.ini.
set -euo pipefail

MODE=${1:---build}
case "$MODE" in
  --build|--finish|--install) ;;
  *) echo "Usage: bash $0 [--build|--finish|--install]" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root" >&2
  exit 1
fi
if [ ! -f /etc/redhat-release ] || ! grep -Eq 'release 8' /etc/redhat-release; then
  echo "This script is for CentOS Stream 8 / RHEL 8 only" >&2
  exit 1
fi

expected='php-common-7.2.24-1.module_el8.2.0+313+b04d0a66'
if ! rpm -q "$expected" >/dev/null 2>&1; then
  echo "Expected $expected, found: $(rpm -q php-common 2>/dev/null || echo none)" >&2
  echo "The script will not replace a different PHP. If this is the same AppStream 7.2.24, rerun with PHP72_FORCE=1." >&2
  if [ "${PHP72_FORCE:-0}" != 1 ]; then
    exit 1
  fi
fi

HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/php-7.2-cve-2026-109618-109619.patch"
SRPM_NAME=php-7.2.24-1.module_el8.2.0+313+b04d0a66.src.rpm
SRPM_URL=https://vault.centos.org/8.2.2004/AppStream/Source/SPackages/$SRPM_NAME

for conf in /etc/dnf/dnf.conf /etc/yum.conf; do
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

TOP=/root/php72-cve-build
if [ "$HERE" = "$TOP" ]; then
  echo "Do not place the script in $TOP: that directory is wiped before the build." >&2
  exit 1
fi

if [ "$MODE" = --install ]; then
  [ -f "$TOP/BUILD-OK" ] && [ "$(cat "$TOP/BUILD-OK")" = 7.2.24-2 ] \
    || { echo "No successful build. Run --build first" >&2; exit 1; }
  (cd "$TOP" && sha256sum -c RPMS.sha256)
else
  [ -f "$PATCH" ] || { echo "Missing patch file: $PATCH" >&2; exit 1; }
fi

if [ "$MODE" = --build ]; then
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -a "$PATCH" "$STAGE/$(basename "$PATCH")"
if [ -f "$HERE/$SRPM_NAME" ]; then
  cp -a "$HERE/$SRPM_NAME" "$STAGE/$SRPM_NAME"
fi

rm -rf "$TOP"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

echo "== source =="
if [ -f "$STAGE/$SRPM_NAME" ]; then
  cp -a "$STAGE/$SRPM_NAME" "$TOP/$SRPM_NAME"
else
  curl -fL --retry 3 --max-time 180 -o "$TOP/$SRPM_NAME" "$SRPM_URL"
fi
( cd "$TOP/SOURCES" && rpm2cpio "$TOP/$SRPM_NAME" | cpio -idm )
mv "$TOP/SOURCES/php.spec" "$TOP/SPECS/php.spec"
cp -a "$STAGE/$(basename "$PATCH")" "$TOP/SOURCES/php-7.2-cve-2026-109618-109619.patch"
SPEC=$TOP/SPECS/php.spec

echo "== spec =="
sed -i '0,/^Release:/s/^Release:.*/Release: 2%{?dist}/' "$SPEC"
sed -i '/^Patch48: php-7.2.7-getallheaders.patch$/a Patch49: php-7.2-cve-2026-109618-109619.patch' "$SPEC"
sed -i '/^%patch48 -p1 -b .getallheaders$/a %patch49 -p1 -b .cve109618' "$SPEC"
awk '
  /^%changelog$/ && !done {
    print
    print "* Wed Oct 21 2026 Local rebuild - 7.2.24-2"
    print "- minimal mitigation for CVE-2026-109618 and CVE-2026-109619"
    print ""
    done = 1
    next
  }
  { print }
' "$SPEC" > "$SPEC.new"
mv "$SPEC.new" "$SPEC"
grep -q '^Patch49: php-7.2-cve-2026-109618-109619.patch$' "$SPEC"
grep -q '^%patch49 -p1 -b .cve109618$' "$SPEC"
grep -q '^Release: 2%{?dist}$' "$SPEC"

echo "== build dependencies =="
dnf install -y dnf-plugins-core rpm-build
if [ -f /etc/yum.repos.d/CentOS-Stream-PowerTools.repo ] || [ -f /etc/yum.repos.d/CentOS-PowerTools.repo ]; then
  dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
    || dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 \
    || true
fi
dnf builddep -y "$SPEC"

echo "== build =="
rpmbuild --define "_topdir $TOP" --define 'runselftest 0' -ba "$SPEC"
(
  cd "$TOP"
  find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
) > "$TOP/RPMS.sha256"
[ -s "$TOP/RPMS.sha256" ] || { echo "RPMs were not built" >&2; exit 1; }
echo 7.2.24-2 > "$TOP/BUILD-OK"
echo "Build ready. RPMs: $TOP/RPMS"
echo "Install separately: bash $0 --install"
exit 0
fi

if [ "$MODE" = --finish ]; then
  [ -x "$TOP/BUILD/php-7.2.24/build-fpm/sapi/fpm/php-fpm" ] \
    || { echo "Built FPM is not in $TOP/BUILD" >&2; exit 1; }
  installed_fpm=$(find "$TOP/BUILDROOT" -type f -name php-fpm -print -quit)
  [ -n "$installed_fpm" ] || { echo "BUILDROOT has no php-fpm, %install did not finish" >&2; exit 1; }
  [ -f "$TOP/SPECS/php.spec" ] || { echo "No spec" >&2; exit 1; }
  rm -f "$TOP/BUILD-OK" "$TOP/RPMS.sha256"
  find "$TOP/RPMS" -type f -name '*.rpm' -delete
  finish_spec=$(mktemp "$TOP/SPECS/php.finish.XXXXXX.spec")
  awk '$0 == "%prep" || $0 == "%build" { print; print "exit 0"; next } { print }' \
    "$TOP/SPECS/php.spec" > "$finish_spec"
  rpmbuild -bb --nocheck --noclean --define "_topdir $TOP" --define 'runselftest 0' "$finish_spec"
  rm -f "$finish_spec"
  if find "$TOP/RPMS" -type f -name '*.rpm' -print0 \
      | xargs -0 -r rpm -qp --requires \
      | grep -q 'rpmlib(ShortCircuited)'; then
    echo "RPMs are marked ShortCircuited and must not be installed" >&2
    exit 1
  fi
  (
    cd "$TOP"
    find RPMS -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$TOP/RPMS.sha256"
  [ -s "$TOP/RPMS.sha256" ] || { echo "RPMs were not built" >&2; exit 1; }
  echo 7.2.24-2 > "$TOP/BUILD-OK"
  echo "Packaged the build that was already there. RPMs: $TOP/RPMS"
  exit 0
fi

echo "== install the php-* packages this SRPM builds that are already installed =="
SPEC=$TOP/SPECS/php.spec
[ -f "$SPEC" ] || { echo "No spec. Run --build first" >&2; exit 1; }
mapfile -t from_spec < <(awk '/^%package / { print "php-" $2 }' "$SPEC")
from_spec+=(php)
declare -A built=()
for name in "${from_spec[@]}"; do
  built["$name"]=1
done

mapfile -t installed < <(rpm -qa --qf '%{NAME}\n' 'php*' | sort -u)
if [ "${#installed[@]}" -eq 0 ]; then
  echo "No installed php* packages found" >&2
  exit 1
fi

to_install=()
for name in "${installed[@]}"; do
  shopt -s nullglob
  matches=("$TOP"/RPMS/*/"${name}"-7.2.24-2*.rpm)
  shopt -u nullglob
  if [ -z "${built[$name]:-}" ]; then
    echo "skip $name: this SRPM does not build it"
    continue
  fi
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "Expected one RPM for $name, found: ${#matches[@]}" >&2
    printf '  %s\n' "${matches[@]:-none}" >&2
    exit 1
  fi
  to_install+=("${matches[0]}")
done
if [ "${#to_install[@]}" -eq 0 ]; then
  echo "Nothing to install" >&2
  exit 1
fi

common=$(printf '%s\n' "${to_install[@]}" | grep '/php-common-' | head -1)
[ -n "$common" ] || { echo "php-common was not built" >&2; exit 1; }
new_ini=$(rpm -qpl "$common" | grep -E '/php\.ini$' || true)
[ "$new_ini" = "/etc/php.ini" ] || { echo "New php.ini: ${new_ini:-none}, need /etc/php.ini" >&2; exit 1; }
now=$(php -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");' 2>/dev/null || true)
[ -z "$now" ] || [ "$now" = /etc ] || { echo "PHP reads ${now}, but the package installs /etc/php.ini" >&2; exit 1; }

rpm -Uvh --test "${to_install[@]}"
backup=$(mktemp -d "$TOP/pre-install.XXXXXX")
tar -C / -czf "$backup/etc-php.tar.gz" etc/php.ini etc/php.d etc/php-fpm.d 2>/dev/null || true
rpm -Uvh "${to_install[@]}"
systemctl restart php-fpm
systemctl is-active --quiet php-fpm

fpm=$(command -v php-fpm || true)
if [ -z "$fpm" ]; then
  fpm=/usr/sbin/php-fpm
fi
if ! nm -D "$fpm" | grep -q ' zend_mm_safe_error_ex$'; then
  echo "zend_mm_safe_error_ex is missing from $fpm, the patch did not land in the binary" >&2
  exit 1
fi
parts=$(php -n -r 'echo ini_get("max_multipart_body_parts");')
[ "$parts" = -1 ] || { echo "max_multipart_body_parts=$parts, need -1" >&2; exit 1; }

echo "== done =="
rpm -q php-common php-cli php-fpm
php -v
php -r 'echo "max_multipart_body_parts=", ini_get("max_multipart_body_parts"), "\n";'
echo "symbol: $(nm -D "$fpm" | awk '/ zend_mm_safe_error_ex$/{print}')"
echo "RPMs are in $TOP/RPMS. dnf module reset php brings back the vulnerable AppStream package."
