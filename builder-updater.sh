#!/bin/bash
# End-user entry point on a host that already runs PHP (EL7/EL8).
#
#   bash builder-updater.sh              # scan installed PHP → say install or build
#   bash builder-updater.sh --install ID # install ready RPMs (RPMS/ preferred)
#   bash builder-updater.sh --build ID   # build from source when no RPMs are ready
#
# Flow for the user:
#   1) Run with no args — sees what PHP is installed and what to do next.
#   2) If ready RPMs exist under RPMS/ (or a local BUILD-OK) → --install ID.
#   3) If no RPMs → --build ID, then --install ID.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-}
TARGET=${2:-}

die() { echo "ERROR: $*" >&2; exit 1; }

if [ -f /etc/redhat-release ] && grep -Eq 'release 7([. ]|$)' /etc/redhat-release; then
  OS=el7
elif [ -f /etc/redhat-release ] && grep -Eq 'release 8([. ]|$)' /etc/redhat-release; then
  OS=el8
else
  OS=unknown
fi

# dir|id|os|family|label|package|marker|ready|nevra_glob|script
rows=()

load_catalog() {
  local dir=$1 key value id os family label package marker ready glob script
  id= os= family= label= package= marker= ready= glob=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      id) id=$value ;;
      os) os=$value ;;
      family) family=$value ;;
      label) label=$value ;;
      package) package=$value ;;
      marker) marker=$value ;;
      ready) ready=$value ;;
      nevra_glob) glob=$value ;;
      *) die "$dir/CATALOG: unknown field $key" ;;
    esac
  done < "$dir/CATALOG"
  [ -n "$id" ] && [ -n "$os" ] && [ -n "$family" ] && [ -n "$label" ] \
    && [ -n "$package" ] && [ -n "$marker" ] \
    || die "$dir/CATALOG is incomplete"
  shopt -s nullglob
  local scripts=("$dir"/build-*.sh)
  shopt -u nullglob
  [ "${#scripts[@]}" -eq 1 ] || die "$dir: need exactly one build-*.sh, found ${#scripts[@]}"
  script=${scripts[0]}
  if [ -n "$ready" ] && [ "${ready#/}" = "$ready" ]; then
    ready=$HERE/$ready
  fi
  rows+=("$dir|$id|$os|$family|$label|$package|$marker|$ready|$glob|$script")
}

shopt -s nullglob
catalog_dirs=(
  "$HERE"/php*-rpm-app/el7
  "$HERE"/php*-rpm-app/el8
  "$HERE"/php*-rpm-remi/el7
  "$HERE"/php*-rpm-remi/el8
)
shopt -u nullglob
[ "${#catalog_dirs[@]}" -gt 0 ] || die "No php*-rpm-app/elN or php*-rpm-remi/elN directories"
for dir in "${catalog_dirs[@]}"; do
  [ -f "$dir/CATALOG" ] || die "Missing $dir/CATALOG"
  load_catalog "$dir"
done

find_row() {
  local id=$1 line
  for line in "${rows[@]}"; do
    IFS='|' read -r _ row_id _ <<<"$line"
    [ "$row_id" = "$id" ] && { printf '%s\n' "$line"; return 0; }
  done
  return 1
}

# Highest VERSION-RELEASE RPM for an exact package name under a tree.
# File mtimes are deliberately ignored: ready trees can contain regression
# fixtures and copied files whose timestamp says nothing about RPM ordering.
newest_rpm_for() {
  local tree=$1 name=$2
  [ -d "$tree" ] || return 0
  local f rpm_name vr
  while IFS= read -r -d '' f; do
    read -r rpm_name vr < <(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE}\n' "$f")
    [ "$rpm_name" = "$name" ] || continue
    printf '%s|%s\n' "$vr" "$f"
  done < <(find "$tree" -type f -name "${name}-*.rpm" \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' -print0) \
    | LC_ALL=C sort -t '|' -k1,1V \
    | awk -F '|' 'END{print substr($0, index($0, "|") + 1)}'
  # All published PHP builds use numeric VERSION-RELEASE values for which
  # GNU version sort has the same ordering needed here.
}

# Source of ready packages: shipped RPMS/ first, then a successful local build.
rpm_source() {
  local marker=$1 ready=$2 package=$3
  local f
  if [ -n "$ready" ]; then
    f=$(newest_rpm_for "$ready" "$package")
    if [ -n "$f" ]; then
      printf 'ready|%s|%s\n' "$ready" "$f"
      return 0
    fi
  fi
  if [ -n "$marker" ] && [ -f "$marker/BUILD-OK" ] && [ -d "$marker/RPMS" ]; then
    f=$(newest_rpm_for "$marker/RPMS" "$package")
    if [ -n "$f" ]; then
      printf 'build|%s|%s\n' "$marker/RPMS" "$f"
      return 0
    fi
  fi
  printf 'none||\n'
}

rpm_vr() {
  # path -> VERSION-RELEASE
  rpm -qp --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

installed_line() {
  local pkg=$1
  rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null || return 1
}

matches_glob() {
  local installed=$1 glob=$2
  [ -z "$glob" ] && return 0
  # shellcheck disable=SC2254
  case "$installed" in
    $glob) return 0 ;;
    *) return 1 ;;
  esac
}

# Install already-present packages from exactly the same source build as the
# selected core RPM. This prevents mixing -1/-2 regression fixtures or partial
# builds that happen to share package names.
install_from_tree() {
  local tree=$1 package=$2 core_rpm=$3
  local -a to_install=()
  local -A by_name=()
  local f name vr arch source core_vr core_source stem installed installed_source
  local expected_conf wrong_conf backup php_bin fpm_bin fpm_package service
  local new_ini expected_version current_conf pid scl manifest rel expected actual live
  local core_prefix core_major
  read -r core_vr core_source < <(rpm -qp --qf '%{VERSION}-%{RELEASE} %{SOURCERPM}\n' "$core_rpm")
  [ -n "$core_vr" ] && [ -n "$core_source" ] || die "Cannot read RPM metadata: $core_rpm"
  core_prefix=${core_source%%-[0-9]*}
  core_major=${core_vr%%.*}

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read -r name vr arch source < <(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH} %{SOURCERPM}\n' "$f")
    [ "$vr" = "$core_vr" ] && [ "$source" = "$core_source" ] || continue
    case "$arch" in x86_64|noarch) ;; *) continue ;; esac
    [ -z "${by_name[$name]:-}" ] || die "Duplicate $name for $core_vr in $tree"
    by_name[$name]=$f
  done < <(find "$tree" -type f -name '*.rpm' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)

  [ -n "${by_name[$package]:-}" ] || die "Tree $tree has no $package RPM"
  [ "${by_name[$package]}" = "$core_rpm" ] || die "Core RPM selection is inconsistent in $tree"

  stem=${package%-common}
  # This release kit is validated for FPM only. Do not silently update an
  # Apache module or LiteSpeed SAPI that has no matching post-install checks.
  rpm -q "$stem" >/dev/null 2>&1 \
    && die "$stem (Apache/mod_php) is installed; ready-RPM installation is FPM-only"
  rpm -q "${stem}-litespeed" >/dev/null 2>&1 \
    && die "${stem}-litespeed is installed; ready-RPM installation is FPM-only"
  if rpm -qa "${stem}-oci8*" 2>/dev/null | grep -q .; then
    die "an OCI8 package for $stem is installed; ready-RPM installation is FPM-only"
  fi

  # Install the common package and every other package from this tree that is already on the box.
  while IFS='|' read -r installed installed_source; do
    if [ -n "${by_name[$installed]:-}" ]; then
      to_install+=("${by_name[$installed]}")
      unset "by_name[$installed]"
    else
      case "$installed_source" in
        "${core_prefix}-${core_major}."*)
          die "Installed core package $installed has no replacement in $core_source"
          ;;
        *) echo "Leaving external package: $installed" ;;
      esac
    fi
  done < <(rpm -qa --qf '%{NAME}|%{SOURCERPM}\n' "${stem}*" | sort -u)
  if [ -n "${by_name[$package]:-}" ]; then
    to_install+=("${by_name[$package]}")
  fi
  [ "${#to_install[@]}" -gt 0 ] || die "Nothing to install from $tree"

  # EL7 php84/php85 need the private library RPM and the SCL runtime even
  # though those NEVRAs do not match the PHP source package.
  case "$package" in
    php84-php-common|php85-php-common)
      local scl_name rt_evr support_name support_evr found n v already x
      scl_name=${package%-php-common}
      if [ "$scl_name" = php84 ]; then
        rt_evr=8.4-3.el7.remi.local
      else
        rt_evr=8.5-3.el7.remi.local
      fi
      add_exact() {
        support_name=$1
        support_evr=$2
        found=
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          read -r n v < <(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE}\n' "$f")
          if [ "$n" = "$support_name" ] && [ "$v" = "$support_evr" ]; then
            found=$f
            break
          fi
        done < <(find "$tree" -type f -name "${support_name}-*.rpm" ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
        [ -n "$found" ] || die "Tree $tree has no ${support_name}-${support_evr}"
        already=0
        for x in "${to_install[@]}"; do
          [ "$x" = "$found" ] && already=1
        done
        [ "$already" = 1 ] || to_install=("$found" "${to_install[@]}")
      }
      add_exact php-el7-libs 1.0-1.el7.local
      add_exact "${scl_name}-runtime" "$rt_evr"
      ;;
  esac

  for f in "${to_install[@]}"; do
    rpm -K "$f" >/dev/null || die "RPM digest/signature check failed: $f"
    case "$f" in
      "$HERE"/RPMS/*)
        manifest=$HERE/RPMS/SHA256SUMS
        [ -f "$manifest" ] || die "Missing release checksum manifest: $manifest"
        rel=${f#"$HERE/RPMS/"}
        expected=$(awk -v path="$rel" '$2 == path {print $1}' "$manifest")
        [ -n "$expected" ] || die "No release checksum for $rel"
        actual=$(sha256sum "$f" | awk '{print $1}')
        [ "$actual" = "$expected" ] || die "Release checksum mismatch: $rel"
        ;;
    esac
  done

  new_ini=$(rpm -qpl "$core_rpm" | grep -E '/php\.ini$' || true)
  [ -n "$new_ini" ] || die "$core_rpm has no php.ini"
  if [ "$package" = php-common ]; then
    expected_conf=/etc
    wrong_conf=
    php_bin=$(command -v php || true)
    fpm_bin=$(command -v php-fpm || true)
    fpm_package=php-fpm
    service=php-fpm
  else
    scl=${package%-php-common}
    expected_conf=/etc/opt/remi/$scl
    wrong_conf=/opt/remi/$scl/root/etc
    php_bin=/opt/remi/$scl/root/usr/bin/php
    fpm_bin=/opt/remi/$scl/root/usr/sbin/php-fpm
    fpm_package=${scl}-php-fpm
    service=${scl}-php-fpm
  fi
  [ "$(dirname "$new_ini")" = "$expected_conf" ] \
    || die "New php.ini is $new_ini, need $expected_conf/php.ini"
  [ -x "$php_bin" ] || die "PHP CLI is missing: ${php_bin:-not found}"
  rpm -q "$fpm_package" >/dev/null 2>&1 || die "$fpm_package is not installed (FPM-only release)"
  [ -x "$fpm_bin" ] || die "FPM binary is missing: ${fpm_bin:-not found}"
  current_conf=$("$php_bin" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')
  case "$current_conf" in
    "$expected_conf") [ -d "$current_conf" ] || die "Config directory does not exist: $current_conf" ;;
    "$wrong_conf") [ -n "$wrong_conf" ] || die "Unexpected empty config path" ;;
    *) die "PHP reads ${current_conf:-empty}, expected $expected_conf" ;;
  esac

  echo "Testing ${#to_install[@]} RPM(s) from source build $core_source"
  rpm -Uvh --test "${to_install[@]}"
  backup=$(mktemp -d /var/tmp/php2shell-pre-install.XXXXXX)
  rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' "${stem}*" \
    | sort > "$backup/packages.txt"
  if [ "$package" = php-common ]; then
    tar -C / -czf "$backup/config.tar.gz" etc/php.ini etc/php.d etc/php-fpm.d 2>/dev/null || true
  else
    [ -d "$expected_conf" ] \
      && tar -C / -czf "$backup/config.tar.gz" "${expected_conf#/}"
    if [ -n "$wrong_conf" ] && [ -d "$wrong_conf" ]; then
      tar -C / -czf "$backup/legacy-config.tar.gz" "${wrong_conf#/}"
    fi
  fi
  "$php_bin" -m > "$backup/modules.txt"
  echo "Installing $core_vr (downgrades are refused)"
  rpm -Uvh "${to_install[@]}"

  if [ "$package" != php-common ] && [ -d "$expected_conf" ]; then
    while IFS= read -r -d '' saved; do
      live=${saved%.rpmsave}
      [ -e "$live" ] || cp -a "$saved" "$live"
    done < <(find "$expected_conf" -type f -name '*.rpmsave' -print0)
  fi
  expected_version=$(rpm -qp --qf '%{VERSION}' "$core_rpm")
  [ "$("$php_bin" -n -r 'echo PHP_VERSION;')" = "$expected_version" ] \
    || die "Installed PHP version does not match $expected_version"
  [ "$("$php_bin" -n -r 'echo rtrim(PHP_CONFIG_FILE_PATH, "/");')" = "$expected_conf" ] \
    || die "Installed PHP does not read $expected_conf"
  "$php_bin" -d display_startup_errors=1 -d display_errors=stderr -d log_errors=0 \
    -m > "$backup/modules-after.txt"
  "$fpm_bin" -t
  systemctl restart "$service"
  systemctl is-active --quiet "$service"
  pid=$(systemctl show "$service" -p MainPID | cut -d= -f2)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -e "/proc/$pid/exe" ] \
    || die "FPM master is not running"
  cmp -s "$fpm_bin" "/proc/$pid/exe" \
    || die "Running FPM does not match the installed binary"
  echo "FPM restarted. Pre-install state: $backup"
}

propose_one() {
  local id=$1 os=$2 label=$3 pkg=$4 script=$5 marker=$6 ready=$7 glob=$8
  local installed src kind tree rpmf avail_vr inst_vr

  installed=$(installed_line "$pkg") || return 1
  matches_glob "$installed" "$glob" || return 1
  if [ "$os" != "$OS" ]; then
    echo "$id: $installed is installed, but this build is for $os (this host is $OS)."
    return 0
  fi

  src=$(rpm_source "$marker" "$ready" "$pkg")
  IFS='|' read -r kind tree rpmf <<<"$src"
  inst_vr=${installed#* }

  echo "$id  $label"
  echo "  installed: $installed"

  if [ "$kind" = none ]; then
    echo "  available: (no ready RPMs in this tree)"
    echo "  next:      build, then install:"
    echo "             bash $HERE/builder-updater.sh --build $id"
    echo "             bash $HERE/builder-updater.sh --install $id"
    return 0
  fi

  avail_vr=$(rpm_vr "$rpmf")
  if [ "$kind" = ready ]; then
    echo "  available: $pkg $avail_vr  (ready RPMs: $tree)"
  else
    echo "  available: $pkg $avail_vr  (local build: $tree)"
  fi
  if [ "$inst_vr" = "$avail_vr" ]; then
    echo "  status:    already up to date — nothing to do"
  else
    echo "  next:      bash $HERE/builder-updater.sh --install $id"
  fi
}

run_install() {
  local id=$1 line dir os pkg marker ready glob script src kind tree rpmf installed
  line=$(find_row "$id") || die "Unknown ID: $id"
  IFS='|' read -r dir id os _ _ pkg marker ready glob script <<<"$line"
  [ "$os" = "$OS" ] || die "$id is for $os, this system is $OS"
  installed=$(installed_line "$pkg") || die "$pkg is not installed on this host"
  matches_glob "$installed" "$glob" \
    || die "$installed does not match the required profile: ${glob:-$pkg}"

  src=$(rpm_source "$marker" "$ready" "$pkg")
  IFS='|' read -r kind tree rpmf <<<"$src"
  if [ "$kind" = ready ]; then
    install_from_tree "$tree" "$pkg" "$rpmf"
    echo
    echo "Done. The FPM service was validated and restarted."
    return 0
  fi

  if [ "$kind" = build ]; then
    echo "Run the build script's verified installer: bash $script --install"
    bash "$script" --install
    return 0
  fi

  # Fall back to the build script's own --install (requires a local BUILD-OK).
  [ -f "$marker/BUILD-OK" ] || die "No ready RPMs for $id. Build first: bash $HERE/builder-updater.sh --build $id"
  echo "Run: bash $script --install"
  bash "$script" --install
}

run_build() {
  local id=$1 line os script
  line=$(find_row "$id") || die "Unknown ID: $id"
  IFS='|' read -r _ id os _ _ _ _ _ _ script <<<"$line"
  [ "$os" = "$OS" ] || die "$id is for $os, this system is $OS"
  echo "Run: bash $script --build"
  bash "$script" --build
}

if [ "$MODE" = --build ] || [ "$MODE" = --install ]; then
  [ -n "$TARGET" ] || die "Need an ID, for example el7-remi-74"
  [ "$(id -u)" -eq 0 ] || die "Build and install require root"
  if [ "$MODE" = --install ]; then
    run_install "$TARGET"
  else
    run_build "$TARGET"
  fi
  exit 0
fi

if [ -n "$MODE" ]; then
  die "Usage: bash $0 [--build|--install ID]"
fi

echo "System: $OS"
echo "Scans installed PHP from the catalog."
echo "Prefers ready packages under RPMS/; proposes --build only when they are missing."
echo

found=0
if [ "$OS" = unknown ]; then
  echo "This host is not EL7/EL8 — install/build are disabled."
  echo "Copy this tree to the CentOS/RHEL/Alma/Rocky 7 or 8 host that runs PHP."
  echo
else
  for line in "${rows[@]}"; do
    IFS='|' read -r _ id os _ label pkg marker ready glob script <<<"$line"
    [ "$os" = "$OS" ] || continue
    if propose_one "$id" "$os" "$label" "$pkg" "$script" "$marker" "$ready" "$glob"; then
      echo
      found=1
    fi
  done
  if [ "$found" = 0 ]; then
    echo "No matching PHP from the catalog is installed on this host."
    echo
  fi
fi

echo "Installed PHP packages on this host:"
rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' \
  'php-common' 'php??-php-common' 'php8?-php-common' 2>/dev/null | sort || true
echo
if [ "$OS" != unknown ]; then
  echo "Known IDs for $OS:"
  for line in "${rows[@]}"; do
    IFS='|' read -r dir id os _ label _ _ _ _ <<<"$line"
    [ "$os" = "$OS" ] || continue
    echo "  $id  $label"
  done
  echo
fi
echo "Examples:"
echo "  bash $HERE/builder-updater.sh"
echo "  bash $HERE/builder-updater.sh --install el8-remi-82"
echo "  bash $HERE/builder-updater.sh --build el8-remi-82"
