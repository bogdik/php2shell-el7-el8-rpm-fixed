#!/bin/bash
# The unpackaged "make install" into /opt/php-el7-libs is gone.
# Libraries are the php-el7-libs RPM, built by the shared script.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec bash "$HERE/../../php-el7-libs/build-rpm.sh" "$@"
