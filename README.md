# PHP RPM rebuilds for CVE-2026-109618 / CVE-2026-109619

Local rebuilds of Remi and AppStream PHP for **CentOS / RHEL / Alma / Rocky 7 and 8** (including **CentOS Stream 8**). They close the upload-progress → LFI chain (chain A) that reaches `uid=48(apache)` on stock packages where that path is still open.

This tree is meant for a host that **already runs** the matching PHP. It does not invent a new stack and does not replace Remi’s or AppStream’s packaging model — it ships a bumped release of the same packages, with configs left where they belong (`/etc` for modular/system PHP, `/etc/opt/remi/phpXX` for SCL).

Regression results (both SAPIs, stock vs ours): [`REGRESSION-php2shell.md`](REGRESSION-php2shell.md) · Russian: [`REGRESSION-php2shell.ru.md`](REGRESSION-php2shell.ru.md).

---

## What you do as an end user

Copy this tree onto the EL7 or EL8 machine that runs PHP, then:

```bash
bash builder-updater.sh
```

The script:

1. Detects EL7 / EL8.
2. Looks at installed PHP packages that this tree knows how to patch.
3. Prefers **ready RPMs under `RPMS/`**.
4. Tells you one next step: `--install ID`, or `--build ID` then `--install ID` if nothing is ready.

```bash
bash builder-updater.sh --install el8-remi-82   # ready packages present
bash builder-updater.sh --build   el8-remi-82   # only when RPMs are missing
bash builder-updater.sh --install el8-remi-82
```

`--install` and `--build` require **root**. Install updates only packages that are already installed (plus the core `php-common` / `phpXX-php-common`). After install, restart `php-fpm` / `httpd` if the packages did not do it for you.

---

## Platforms

| Host | Our EL8 packages | Our EL7 packages |
| --- | --- | --- |
| CentOS Stream 8, RHEL 8, Rocky 8, Alma 8 | Yes (same `el8` / Remi module tags) | No |
| CentOS 7 / RHEL 7 | No | Yes (Remi SCL) |

Requirements:

- The **same PHP family and stream** must already be installed (AppStream `php:7.2`, Remi `php:remi-8.2`, SCL `php74`, …).
- Do **not** mix EL7 RPMs onto EL8 or AppStream onto Remi (or the reverse).
- FPM-oriented installs: the build scripts refuse Apache module / LiteSpeed / oci8 layouts they were not written for.

---

## Coverage (summary)

Where stock was open, ours closes chain A on FPM and Apache. Where stock was already closed, we either bump release without a second CVE patch, or ship no package.

### EL7 — Remi SCL

| Version | Stock (open) | Ours | Notes |
| --- | --- | --- | --- |
| 5.6 … 7.3 | open | closed | CVE patch added on top of Remi SRPM |
| 7.4.33 | open | `7.4.33-32` | Paths forced under `/etc/opt/remi/php74` |
| 8.0 / 8.1 | open | closed | Official fix present; release bumped + SCL paths |
| 8.2.20 | open | closed by **8.2.35-2** | No separate 8.2.20 RPM in this tree |
| 8.2.35 / 8.3.36 | open (upload progress still writes the name) | `-2`, progress off | |
| 8.4 / 8.5 | no official EL7 binary | `8.4.27-3` / `8.5.12-3`, passed and portable | private libs are packaged in `php-el7-libs`; obsolete non-portable `-2` RPMs are not distributed |

### EL8 — AppStream

| Stream | Stock | Ours |
| --- | --- | --- |
| 7.2.24 | open | `7.2.24-2` |
| 7.3.20 | open | `7.3.20-2` |
| 7.4.33-8 | tested chain A not reproduced | no package needed |
| 8.0.30 | open | `8.0.30-2` |
| 8.2.35 | fixed upstream; tested chain A not reproduced | no package |

### EL8 — Remi (module or SCL)

| Version | Stock | Ours |
| --- | --- | --- |
| 5.6 / 7.0 / 7.1 (SCL) | open | `-48` / `-35` |
| 7.2.34 / 7.3.33 (module) | open | patched release |
| 7.4.33-31 | tested chain A not reproduced | no separate `-2` |
| 8.0.30-21 / 8.1.34-6 | tested chain A not reproduced | release bump only (`-22` / `-7`) |
| 8.2 … 8.5 | open (progress still writes the name) | `-2`, progress off |

Full matrix and method: [`REGRESSION-php2shell.md`](REGRESSION-php2shell.md).

---

## Layout

```
builder-updater.sh          ← end-user entry point
RPMS/                       ← ready binaries (preferred by the updater)
  el7/remi/…
  el8/app/…
  el8/remi/…
  SHA256SUMS                ← checksums enforced by the updater
php-el7-libs/               ← private zlib/libxml2/curl/sqlite/libpq RPM for EL7 8.4/8.5
php72-rpm-app/el8/          ← one version × one vendor × one OS
php72-rpm-remi/el7/
php82-rpm-remi/{el7,el8}/
…
AGENT-BUILD.md              ← how to author new build scripts
REGRESSION-php2shell.md     ← lab results
```

Each `phpVERSION-rpm-{app|remi}/elN/` holds:

- `CATALOG` — id, package name, ready path, version glob
- exactly one `build-*.sh`
- patches for that build

AppStream and Remi never share a folder, even when the PHP number matches (`php72-rpm-app` vs `php72-rpm-remi`).

---

## Ready RPMs vs build

1. If `CATALOG` has `ready=RPMS/…` and those files exist → **`--install ID`**.
   The updater verifies the release SHA256, RPM digest, exact profile and a dry-run transaction first.
2. Else if a local `BUILD-OK` + `RPMS` from a previous `--build` exist → install from that.
3. Else → **`--build ID`**, then `--install ID`.

Builds run as root, take a long time, and write under `/root/…-build/`. They do not touch the live PHP until you explicitly `--install`. If compile finished but packaging failed, use the script’s `--finish` (see the package README) — do not delete `BUILD/`.

Before publishing the tree, run the read-only release checks:

```bash
bash verify-release.sh
```

---

## IDs the updater understands

| ID | What |
| --- | --- |
| `el7-remi-56` … `el7-remi-85` | Remi SCL on EL7 |
| `el8-app-72` `el8-app-73` `el8-app-74` `el8-app-80` | AppStream module streams on EL8 |
| `el8-remi-56` `el8-remi-70` `el8-remi-71` | Remi SCL on EL8 |
| `el8-remi-72` … `el8-remi-85` | Remi `php:remi-X.Y` modules on EL8 |

Run `bash builder-updater.sh` on the target host to see which of these match what is installed.

---

## Important limits

- This is **not** a yum/dnf repository and **not** an official Remi/AppStream update channel. You install our RPMs from this tree (or rebuild them).
- Closing chain A is the acceptance bar used in the regression. Other public chains were not used as pass/fail here; see the report.
- Do not use these packages as a general “upgrade PHP” path across major versions — stay on the same stream you already run.
- Agent/build conventions for new versions: [`AGENT-BUILD.md`](AGENT-BUILD.md). Per-package details: each `php*-rpm-*/README.md`.

---

## Quick check after install

```bash
php -r 'echo PHP_VERSION, "\n";'
# SCL: scl enable phpXX 'php -r "…"'  or the phpXX-php binary
nm -D "$(command -v php-fpm)" 2>/dev/null | grep zend_mm_safe_error_ex || true
php -i | grep max_multipart_body_parts || true
systemctl restart php-fpm   # or phpXX-php-fpm / httpd as appropriate
```

Then re-check the application’s `fastcgi_pass` / socket path if anything under `/var/opt/remi` moved in an older broken local build.
