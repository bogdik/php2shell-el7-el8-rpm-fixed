# PHP 8.3.36 Remi

Official 8.3.36 does not disable the `session.upload_progress` callback: the
filename is still written into the session. Patch
`el7/php-8.3.36-upload-progress-off.patch` returns before that write.
Both builds use it.

## EL7, SCL php83

Goal: update installed EL7 PHP 8.3.x under `/opt/remi/php83` to
`php83-php-8.3.36-2.el7.remi.local`. Service: `php83-php-fpm`.
This is a local package adaptation, not an official Remi binary release for EL7.
Configs: `/etc/opt/remi/php83`. State: `/var/opt/remi/php83`.

```bash
bash el7/build-php83-el7.sh --build
bash el7/build-php83-el7.sh --install
```

Build tools and dependencies are installed. `--build` does not update
application PHP packages.
On EL7 you need ICU 73 and fixes in `ext/ffi/ffi.c` and `ext/openssl/xp_ssl.c`;
the EL7 script applies them.
The Remi spec contains `%patch -P`, which rpm 4.11 does not run. The script
rewrites those to `%patchN`.
`yum-builddep` on EL7 does not accept `--define`, so dependencies are installed
from an intermediate SRPM.

If compilation finished but packaging failed, do not delete `/root/php83-8.3.36-el7/BUILD`:

```bash
bash el7/build-php83-el7.sh --finish
```

It does not use `--short-circuit`: such RPMs cannot be installed.

## EL8, module php:remi-8.3

System PHP, not SCL. Configs: `/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`.
Release `8.3.36-2.module_php.8.3.el8.remi`. The EL7 FFI and OpenSSL fixes are
not needed here.

```bash
bash el8/build-php83-el8.sh --build
bash el8/build-php83-el8.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php83-el8-remi-build/BUILD`:

```bash
bash el8/build-php83-el8.sh --finish
```
