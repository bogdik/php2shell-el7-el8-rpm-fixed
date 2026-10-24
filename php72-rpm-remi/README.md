# PHP 7.2.34 Remi SCL for CentOS 7

Configs: `/etc/opt/remi/php72`. State: `/var/opt/remi/php72`.
The patch lives next to the script: `php-7.2.34-remi-cve-2026-109618-109619.patch`.

```bash
bash el7/build-php72-el7.sh --build
bash el7/build-php72-el7.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php72-el7-build/BUILD`:

```bash
bash el7/build-php72-el7.sh --finish
```

This is not an AppStream package. Do not install it on Stream 8.
