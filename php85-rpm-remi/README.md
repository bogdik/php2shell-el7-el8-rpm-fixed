# PHP 8.5.12 Remi module for EL8

System module `php:remi-8.5`, not SCL. Configs: `/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`.

Official `8.5.12` leaves the `session.upload_progress` callback enabled, so the
filename ends up in the session. Patch `php-8.5.12-upload-progress-off.patch`
returns before that write.

Remi does not publish PHP 8.5 for EL7. `el7/` takes the same system SRPM and
builds SCL `php85-php-*`: configs `/etc/opt/remi/php85`, state `/var/opt/remi/php85`.
Compiler: devtoolset-11; OpenSSL 1.1.1 from `openssl11`; ICU 73; bundled pcre2.
`adapt-spec.py` removes `Recommends` and `%patch -P`, which rpm 4.11 does not understand.
The EL7 build links private zlib, libxml2, curl, SQLite and libpq from the
`php-el7-libs` RPM (`/opt/php-el7-libs`). Release `8.5.12-3.el7.remi.local`
requires that RPM plus `php85-runtime` and `openssl11-libs`, so a clean CentOS 7
installs the set with a normal dependency transaction. The older non-portable
`-2` RPMs are not distributed.

```bash
bash el8/build-php85-el8.sh --build
bash el8/build-php85-el8.sh --install
bash el7/build-php85-el7.sh --build
bash el7/build-php85-el7.sh --install
```

If compilation finished but packaging failed, do not delete the corresponding `BUILD` directory:

```bash
bash el8/build-php85-el8.sh --finish
bash el7/build-php85-el7.sh --finish
```
