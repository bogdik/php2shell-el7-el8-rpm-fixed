# PHP 7.4.33-32 for CentOS 7 / Remi SCL php74

Local rebuild of installed `php74-php` 7.4.33. Service: `php74-php-fpm`.
Configs stay under `/etc/opt/remi/php74`, state under `/var/opt/remi/php74`.

The directory contains only the script and patches. SRPM
`php74-php-7.4.33-31.remi.src.rpm` is fetched by the script:

https://rpms.remirepo.net/SRPMS/php74-php-7.4.33-31.remi.src.rpm

Build dependencies are installed via `yum`. Finished RPMs appear under
`/root/php74-31/RPMS`, not in this directory.

```bash
bash el7/build-php74-31.sh --build
bash el7/build-php74-31.sh --install
```

If compilation finished but packaging failed, do not delete `/root/php74-31/BUILD`.
Repackage without recompiling:

```bash
bash el7/build-php74-31.sh --finish
```

Package release is 7.4.33-32. It replaces a local 31 whose directories
had drifted into `/opt/remi/php74/root`.
