# PHP 8.2.35 Remi

Official 8.2.35 does not disable the `session.upload_progress` callback: the
filename is still written into the session. Patch
`el7/php-8.2.35-upload-progress-off.patch` returns before that write.
Both builds use it.

## EL7, SCL php82

Configs: `/etc/opt/remi/php82`. State: `/var/opt/remi/php82`.
Release `8.2.35-2.el7.remi.local`. On OpenSSL 1.0.2 you also need
`el7/php-8.2.35-openssl-asn1.patch`.

```bash
bash el7/build-php82-el7.sh --build
bash el7/build-php82-el7.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php82-el7-build/BUILD`:

```bash
bash el7/build-php82-el7.sh --finish
```

## EL8, module php:remi-8.2

System PHP, not SCL. Configs: `/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`.
Release `8.2.35-2.module_php.8.2.el8.remi`. The OpenSSL patch is not needed here.

```bash
bash el8/build-php82-el8.sh --build
bash el8/build-php82-el8.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php82-el8-remi-build/BUILD`:

```bash
bash el8/build-php82-el8.sh --finish
```
