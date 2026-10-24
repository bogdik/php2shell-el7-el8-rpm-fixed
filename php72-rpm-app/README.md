# PHP 7.2.24 AppStream for CentOS Stream 8 / RHEL 8

System PHP. Configs stay at `/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`.
The patch lives next to the script: `php-7.2-cve-2026-109618-109619.patch`.
The SRPM is fetched from vault.centos.org if it is not already beside the script.

```bash
bash el8/build-php72-el8.sh --build
bash el8/build-php72-el8.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php72-cve-build/BUILD`:

```bash
bash el8/build-php72-el8.sh --finish
```

Do not install the Remi EL7 package here.
