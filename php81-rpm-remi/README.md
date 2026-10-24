# PHP 8.1.34 Remi

## EL8, module php:remi-8.1

System PHP, configs under `/etc/php.ini`. Official `8.1.34-6` already
contains the fix. The script builds release `7` without a second patch.

```bash
bash el8/build-php81-el8.sh --build
bash el8/build-php81-el8.sh --install
```
