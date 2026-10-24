Name: php-el7-libs
Version: 1.0
Release: 1.el7.local
Summary: Private zlib, libxml2, curl, SQLite and libpq for the EL7 PHP 8.4/8.5 backport
License: Zlib AND MIT AND curl AND Public Domain AND PostgreSQL
URL: https://www.zlib.net/
BuildRequires: devtoolset-11-gcc
BuildRequires: devtoolset-11-gcc-c++
BuildRequires: devtoolset-11-binutils
BuildRequires: openssl11-devel
BuildRequires: make
BuildRequires: pkgconfig
BuildRequires: bison
BuildRequires: flex
Requires: openssl11-libs

# Sources are staged by fetch-sources.sh. rpmbuild must not download them.
Source0: zlib-1.3.1.tar.gz
Source1: libxml2-2.9.14.tar.xz
Source2: curl-8.4.0.tar.xz
Source3: sqlite-autoconf-3460100.tar.gz
Source4: postgresql-10.23.tar.bz2

%description
Shared libraries newer than CentOS 7, installed under /opt/php-el7-libs
and found via RPATH plus the SCL LD_LIBRARY_PATH. They are not added to
the system linker path.

%package devel
Summary: Headers and build tools for php-el7-libs
Requires: %{name}%{?_isa} = %{version}-%{release}

%description devel
Headers, pkg-config files, unversioned shared-library symlinks and the
curl-config / pg_config helpers used while building PHP.

%prep
%setup -q -c -T -n %{name}-%{version}
tar -xf %{SOURCE0}
tar -xf %{SOURCE1}
tar -xf %{SOURCE2}
tar -xf %{SOURCE3}
tar -xf %{SOURCE4}

%build
set -euo pipefail
. /opt/rh/devtoolset-11/enable
PREFIX=/opt/php-el7-libs
# Stage outside the RPM buildroot. rpmbuild wipes %{buildroot} before %%install.
STAGE=%{_builddir}/el7-stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
export PATH
rpath="-Wl,-rpath,${PREFIX}/lib -Wl,-rpath,/usr/lib64/openssl11"
jobs=$(nproc)

# EPEL openssl11 names its .pc files openssl11 / libssl11 / libcrypto11.
# Autoconf for curl and PostgreSQL looks for openssl.pc, so invent a private
# alias that still points at /usr/lib64/openssl11 and /usr/include/openssl11.
ssl_pc=%{_builddir}/openssl11-pkgconfig
mkdir -p "$ssl_pc"
[ -d /usr/include/openssl11 ] || { echo "openssl11 headers missing" >&2; exit 1; }
[ -e /usr/lib64/openssl11/libssl.so ] || { echo "openssl11 libraries missing" >&2; exit 1; }
cat > "$ssl_pc/openssl.pc" << 'EOF'
prefix=/usr
libdir=${prefix}/lib64/openssl11
includedir=${prefix}/include/openssl11
Name: OpenSSL
Description: OpenSSL 1.1.1 (openssl11)
Version: 1.1.1k
Libs: -L${libdir} -lssl -lcrypto -Wl,-rpath,/usr/lib64/openssl11
Cflags: -I${includedir}
EOF
# Prefer the private alias over any system openssl.pc that may exist.
export PKG_CONFIG_PATH="${ssl_pc}:${PKG_CONFIG_PATH:-}"

cd zlib-1.3.1
./configure --prefix="$PREFIX"
make -j"$jobs"
make install DESTDIR="$STAGE"

export CPPFLAGS="-I${STAGE}${PREFIX}/include"
export LDFLAGS="-L${STAGE}${PREFIX}/lib ${rpath}"
# Rewrite staged .pc files to the DESTDIR tree so later configures find the
# just-built libraries. Do not set PKG_CONFIG_SYSROOT_DIR: openssl11 lives
# under the real /usr, not under STAGE.
rewrite_pc() {
  local pc
  for pc in "${STAGE}${PREFIX}/lib/pkgconfig"/*.pc; do
    [ -f "$pc" ] || continue
    sed -i \
      -e "s|^prefix=${PREFIX}|prefix=${STAGE}${PREFIX}|" \
      -e "s|^prefix=/opt/php-el7-libs|prefix=${STAGE}${PREFIX}|" \
      "$pc"
  done
}
rewrite_pc
export PKG_CONFIG_PATH="${STAGE}${PREFIX}/lib/pkgconfig:${ssl_pc}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
unset PKG_CONFIG_SYSROOT_DIR || true

cd ../libxml2-2.9.14
./configure --prefix="$PREFIX" --without-python --with-zlib="${STAGE}${PREFIX}" --disable-static
make -j"$jobs"
make install DESTDIR="$STAGE"
rewrite_pc

cd ../curl-8.4.0
./configure --prefix="$PREFIX" --with-openssl --with-zlib="${STAGE}${PREFIX}" \
  --disable-ldap --without-libpsl --without-nghttp2 --without-libidn2 \
  --disable-manual --disable-static
make -j"$jobs"
make install DESTDIR="$STAGE"
rewrite_pc

cd ../sqlite-autoconf-3460100
./configure --prefix="$PREFIX" --disable-static
make -j"$jobs"
make install DESTDIR="$STAGE"

cd ../postgresql-10.23
./configure --prefix="$PREFIX" --without-readline --with-openssl \
  --without-icu --with-includes=/usr/include/openssl11 \
  --with-libraries=/usr/lib64/openssl11
make -C src/interfaces/libpq -j"$jobs"
make -C src/interfaces/libpq install DESTDIR="$STAGE"
make -C src/bin/pg_config -j"$jobs"
make -C src/bin/pg_config install DESTDIR="$STAGE"
# libpq-fe.h needs these public headers. A full src/include install also
# wants generated server headers we never built.
install -m 644 src/include/postgres_ext.h src/include/pg_config.h \
  src/include/pg_config_ext.h src/include/pg_config_os.h \
  "${STAGE}${PREFIX}/include/"

%install
set -euo pipefail
. /opt/rh/devtoolset-11/enable
# Install the already-built trees into the real buildroot.
make -C zlib-1.3.1 install DESTDIR=%{buildroot}
make -C libxml2-2.9.14 install DESTDIR=%{buildroot}
make -C curl-8.4.0 install DESTDIR=%{buildroot}
make -C sqlite-autoconf-3460100 install DESTDIR=%{buildroot}
make -C postgresql-10.23/src/interfaces/libpq install DESTDIR=%{buildroot}
make -C postgresql-10.23/src/bin/pg_config install DESTDIR=%{buildroot}
install -m 644 postgresql-10.23/src/include/postgres_ext.h \
  postgresql-10.23/src/include/pg_config.h \
  postgresql-10.23/src/include/pg_config_ext.h \
  postgresql-10.23/src/include/pg_config_os.h \
  %{buildroot}/opt/php-el7-libs/include/
find %{buildroot} -name '*.la' -delete
# Point pkg-config consumers at the private prefix, not the build root.
rpath='-Wl,-rpath,/opt/php-el7-libs/lib -Wl,-rpath,/usr/lib64/openssl11'
for pc in %{buildroot}/opt/php-el7-libs/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  grep -q -- '-rpath,/opt/php-el7-libs/lib' "$pc" && continue
  sed -i "s|^Libs: \\(.*\\)|Libs: \\1 ${rpath}|" "$pc"
  if grep -q '^Libs.private:' "$pc"; then
    sed -i "s|^Libs.private: \\(.*\\)|Libs.private: \\1 ${rpath}|" "$pc"
  fi
done

if grep -R -a -F -q '%{buildroot}' %{buildroot}/opt/php-el7-libs; then
  echo "ERROR: %{buildroot} leaked into installed files" >&2
  grep -R -a -F -l '%{buildroot}' %{buildroot}/opt/php-el7-libs >&2 || true
  exit 1
fi

lic=%{buildroot}%{_datadir}/licenses/%{name}
mkdir -p "$lic"
cp zlib-1.3.1/README "$lic/zlib-README"
cp libxml2-2.9.14/Copyright "$lic/libxml2-Copyright"
cp curl-8.4.0/COPYING "$lic/curl-COPYING"
cp postgresql-10.23/COPYRIGHT "$lic/postgresql-COPYRIGHT"
# SQLite's autoconf tarball has no standalone license file. The blessing
# at the top of sqlite3.h is the published notice.
awk 'BEGIN{p=0} /^\*\// { if (p) { print; exit } } { if (p) print } /^\/\*/ { p=1; print }' \
  sqlite-autoconf-3460100/sqlite3.h > "$lic/sqlite-blessing.txt"
grep -q 'author disclaims copyright' "$lic/sqlite-blessing.txt"

runtime=%{_builddir}/php-el7-libs-runtime.list
devel=%{_builddir}/php-el7-libs-devel.list
all=%{_builddir}/php-el7-libs-all.list
: > "$runtime"
: > "$devel"
find %{buildroot}/opt/php-el7-libs \( -type f -o -type l \) | sort > "$all"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  rel=${path#%{buildroot}}
  base=$(basename "$rel")
  case "$rel" in
    /opt/php-el7-libs/lib/*)
      case "$base" in
        *.so.[0-9]|*.so.[0-9].*|*.so.[0-9][0-9]|*.so.[0-9][0-9].*)
          echo "$rel" >> "$runtime"
          continue
          ;;
      esac
      ;;
  esac
  echo "$rel" >> "$devel"
done < "$all"
[ -s "$runtime" ] || { echo "ERROR: runtime package has no shared libraries" >&2; exit 1; }
[ -s "$devel" ] || { echo "ERROR: devel package is empty" >&2; exit 1; }

%files -f %{_builddir}/php-el7-libs-runtime.list
%dir /opt/php-el7-libs
%dir /opt/php-el7-libs/lib
%license %{_datadir}/licenses/%{name}/zlib-README
%license %{_datadir}/licenses/%{name}/libxml2-Copyright
%license %{_datadir}/licenses/%{name}/curl-COPYING
%license %{_datadir}/licenses/%{name}/postgresql-COPYRIGHT
%license %{_datadir}/licenses/%{name}/sqlite-blessing.txt

%files devel -f %{_builddir}/php-el7-libs-devel.list
%dir /opt/php-el7-libs
%dir /opt/php-el7-libs/lib

%changelog
* Sat Oct 24 2026 Local rebuild
- Package the private EL7 libraries instead of installing them unpackaged
