# PHP 8.0.30 Remi

## EL8, module php:remi-8.0

System PHP, configs under `/etc/php.ini`. Official `8.0.30-21` already
contains the fix. The script builds release `22` without a second patch.

```bash
bash el8/build-php80-el8.sh --build
bash el8/build-php80-el8.sh --install
```
