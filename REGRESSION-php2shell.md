# Regression for CVE-2026-109618 and CVE-2026-109619

Run on 24 October 2026. The HTTP client is a sidecar in the lab network namespace, started from the host. It was not a `docker exec` into the PHP container: the root proxy on the host dropped the second chain A connection, and the host cannot reach `172.17.0.0/16` directly. SELinux is off in both containers. `memory_limit=8M`, `session.upload_progress` is on, `cleanup` is off, session directory `/tmp/sessions`.

Chain A proof is `uid=48(apache)`. The vector name and the verdict are below. Session bodies and reproduction commands are not included.

Scope: in the tables, `closed` means only that tested chain A was not reproduced
in this lab and the upload filename was not written to the session. It is not a
claim that every exploitation chain or the complete CVE class was disproved.

The Russian copy of this report is `REGRESSION-php2shell.ru.md`.

## Official chain A

Chain A reproduced on the official EL8 8.2–8.5 modules, on both SAPIs.

| Package | FPM | Apache |
| --- | --- | --- |
| 8.2.35-1 | uid=48(apache) | uid=48(apache) |
| 8.3.36-1 | uid=48(apache) | uid=48(apache) |
| 8.4.27-1 | uid=48(apache) | uid=48(apache) |
| 8.5.12-1 | uid=48(apache) | uid=48(apache) |

EL7 builds from the same official code, without the second early return: `8.2.35-1` and `8.3.36-1` give `uid=48(apache)` on FPM and on Apache. There is no official 8.4 or 8.5 binary for EL7.

Official Remi `7.4.33-31`, `8.0.30-21`, and `8.1.34-6` do not write the filename on either SAPI, and chain A is not confirmed. Our `8.0.30-22` and `8.1.34-7` behave the same way.

## EL7

Stock is the Remi packages. Ours is the patched release. Stock chain A gave `uid=48(apache)` everywhere it was installed. Our builds do not confirm chain A and do not write the filename into the session.

| Version | Stock | Ours | FPM, stock | FPM, ours | Apache, stock | Apache, ours |
| --- | --- | --- | --- | --- | --- | --- |
| 5.6.40 | 5.6.40-41 | 5.6.40-48 | chain A, RCE | closed | chain A, RCE | closed |
| 7.0.33 | 7.0.33-42 | 7.0.33-48 | chain A, RCE | closed | chain A, RCE | closed |
| 7.1.33 | 7.1.33-29 | 7.1.33-35 | chain A, RCE | closed | chain A, RCE | closed |
| 7.2.34 | 7.2.34-22 | 7.2.34-31 | chain A, RCE | closed | chain A, RCE | closed |
| 7.3.33 | 7.3.33-14 | 7.3.33-23 | chain A, RCE | closed | chain A, RCE | closed |
| 7.4.33 | 7.4.33-15 | 7.4.33-32 | chain A, RCE | closed | chain A, RCE | closed |
| 8.0.30 | 8.0.30-6 | 8.0.30-22 | chain A, RCE | closed | chain A, RCE | closed |
| 8.1.29 | 8.1.29-1 | 8.1.34-7 | chain A, RCE | closed | chain A, RCE | closed |
| 8.2.20 | 8.2.20-1 | no separate RPM, replaced by 8.2.35-2 | chain A, RCE | closed by 8.2.35-2 | chain A, RCE | closed by 8.2.35-2 |
| 8.2.35 | 8.2.35-1 | 8.2.35-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.3.36 | 8.3.36-1 | 8.3.36-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.4.27 | no binary | 8.4.27-3 | — | closed | — | closed |
| 8.5.12 | no binary | 8.5.12-3 | — | closed | — | closed |

`8.2.35-1` and `8.3.36-1` are the official code built for EL7, without `|| true`.

## EL8

| Version | Family | Stock | Ours | FPM, stock | FPM, ours | Apache, stock | Apache, ours |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5.6.40 | Remi SCL | 5.6.40-47 | 5.6.40-48 | chain A, RCE | closed | chain A, RCE | closed |
| 7.0.33 | Remi SCL | 7.0.33-47 | 7.0.33-48 | chain A, RCE | closed | chain A, RCE | closed |
| 7.1.33 | Remi SCL | 7.1.33-34 | 7.1.33-35 | chain A, RCE | closed | chain A, RCE | closed |
| 7.2.24 | AppStream | 7.2.24-1 | 7.2.24-2 | chain A, RCE | closed | chain A, RCE | closed |
| 7.2.34 | Remi | 7.2.34-29 | 7.2.34-30 | chain A, RCE | closed | chain A, RCE | closed |
| 7.3.20 | AppStream | 7.3.20-1 | 7.3.20-2 | chain A, RCE | closed | chain A, RCE | closed |
| 7.3.33 | Remi | 7.3.33-22 | 7.3.33-23 | chain A, RCE | closed | chain A, RCE | closed |
| 7.4.33 | AppStream | 7.4.33-8 | no package | closed | — | closed | — |
| 7.4.33 | Remi | 7.4.33-31 | no separate -2 | closed | — | closed | — |
| 8.0.30 | AppStream | 8.0.30-1 | 8.0.30-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.0.30 | Remi | 8.0.30-21 | 8.0.30-22 | closed | closed | closed | closed |
| 8.1.34 | Remi | 8.1.34-6 | 8.1.34-7 | closed | closed | closed | closed |
| 8.2.35 | Remi | 8.2.35-1 | 8.2.35-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.3.36 | Remi | 8.3.36-1 | 8.3.36-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.4.27 | Remi | 8.4.27-1 | 8.4.27-2 | chain A, RCE | closed | chain A, RCE | closed |
| 8.5.12 | Remi | 8.5.12-1 | 8.5.12-2 | chain A, RCE | closed | chain A, RCE | closed |

Vulnerable control RPMs are not distributed. Ready install trees contain only
the patched packages. There is no `8.2.20` build: stock `8.2.20-1` is open,
while tested chain A is blocked by `8.2.35-2`.

EL7 `8.4.27-3` and `8.5.12-3` retain the same upload-progress-off source patch
as the tested `-2` builds and passed the clean-container portability, CLI and
FPM checks after repackaging the private libraries.

AppStream 7.4.33-8 and Remi 7.4.33-31 are already closed in stock. They have no `-2` of their own.

## Other vectors

Chain C was not confirmed: the proof file is empty. That is not evidence that the bug is closed.

Chain D only watches for a dropped connection. On Apache 8.2–8.5 the drop happens for official `-1` and for our `-2`. The public repository has no full RCE for this chain.

Chain E never reached another worker's state.

eness, 78ResearchLab, and alvarodh5 did not produce `uid=48(apache)`. On this Apache they time out or stop at the first stage, and they do not tell a vulnerable build from a closed one. No new heap offsets were chosen.

On already closed EL7 FPM, Sol0 often follows the access log and reads `uid` from there. That is the lab `include`, not `upload_progress`. That result does not count as chain A.

On 5.6–8.1 the OOM body has no `Allowed memory size` where our patch is installed. On 8.2–8.5 that text remains: that is how the stock bailout of those branches works. For those versions chain A is closed, not the memory-limit message.
