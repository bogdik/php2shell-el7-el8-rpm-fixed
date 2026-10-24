#!/bin/bash
# Build php-el7-libs and php-el7-libs-devel. Optional --install loads them
# with a normal rpm transaction. This is the only supported way to produce
# /opt/php-el7-libs; nothing is copied into /opt outside RPM.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${PHP_EL7_LIBS_TOP:-/root/php-el7-libs-build}
INSTALL=0
if [ "${1:-}" = --install ]; then
  INSTALL=1
elif [ -n "${1:-}" ]; then
  echo "Usage: bash $0 [--install]" >&2
  exit 2
fi
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -f /etc/redhat-release ] && grep -Eq 'release 7([. ]|$)' /etc/redhat-release \
  || { echo "ERROR: php-el7-libs is built on EL7" >&2; exit 1; }

NVR=php-el7-libs-1.0-1.el7.local
DEVEL=php-el7-libs-devel-1.0-1.el7.local
RPMDIR=$TOP/RPMS/x86_64
RUNTIME_RPM=$RPMDIR/${NVR}.x86_64.rpm
DEVEL_RPM=$RPMDIR/${DEVEL}.x86_64.rpm

install_rpms() {
  [ -f "$RUNTIME_RPM" ] && [ -f "$DEVEL_RPM" ] || { echo "ERROR: support RPMs are missing" >&2; exit 1; }
  if rpm -q "$NVR" >/dev/null 2>&1 && rpm -q "$DEVEL" >/dev/null 2>&1; then
    echo "php-el7-libs already installed"
    return 0
  fi
  rpm -Uvh "$RUNTIME_RPM" "$DEVEL_RPM"
}

if [ -f "$RUNTIME_RPM" ] && [ -f "$DEVEL_RPM" ]; then
  [ "$INSTALL" = 1 ] && install_rpms
  echo "php-el7-libs RPMs ready: $RPMDIR"
  exit 0
fi

yum install -y yum-utils rpm-build scl-utils-build gcc gcc-c++ make cpio curl \
  openssl11-devel devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-binutils \
  pkgconfig bison flex
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
bash "$HERE/fetch-sources.sh" "$TOP/SOURCES"
# shellcheck disable=SC1091
. /opt/rh/devtoolset-11/enable
rpmbuild -bb --define "_topdir $TOP" "$HERE/php-el7-libs.spec"
[ -f "$RUNTIME_RPM" ] && [ -f "$DEVEL_RPM" ]
[ "$INSTALL" = 1 ] && install_rpms
echo "php-el7-libs RPMs ready: $RPMDIR"
