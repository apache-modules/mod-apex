# PHP Apex for Apache

Run PHP directly inside Apache with the modern `event` MPM. PHP Apex removes
the PHP-FPM proxy hop and keeps a PHP ZTS runtime ready in every Apache worker
thread.

PHP Apex is available as one ready-to-run Docker image or as matching server
packages for Debian, Ubuntu, Fedora, and Arch Linux.

## Why PHP Apex

- One direct path from Apache to PHP—no FastCGI socket or second service.
- Apache `event` MPM for modern connection handling.
- OPcache and JIT enabled with the supported `apache2handler` SAPI identity.
- APCu, Redis, Imagick, mbstring, intl, zip, bcmath, SOAP, GD, sodium, GMP,
  curl, OpenSSL, SQLite, MySQL PDO, exif, and XSL included.
- CPU-aware server settings through the packaged `php-apex-mode` command.
- Docker, Debian/Ubuntu, Fedora, and Arch delivery options.

## First option: run the Docker Hub image

Docker is the quickest way to run PHP Apex because Apache, PHP 8.4 ZTS, PHP
Apex, OPcache, and the included extensions arrive together.

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run -d \
  --name php-apex \
  --restart unless-stopped \
  -p 8080:80 \
  -v "$PWD/public:/var/www/html:ro" \
  practicalwebuser/mod_apex-apache:php8.4
```

Open `http://SERVER-IP:8080` in a browser. Put your PHP application in the
local `public` folder or replace the volume path with your application’s
document root.

For production, set CPU and memory limits outside the image:

```bash
docker run -d \
  --name php-apex \
  --restart unless-stopped \
  --cpus=4 \
  --memory=2g \
  -p 8080:80 \
  -v /srv/my-app/public:/var/www/html:ro \
  practicalwebuser/mod_apex-apache:php8.4
```

The image reads its available CPU count and chooses matching Apache worker
settings when it starts. See [DOCKER.md](DOCKER.md) for application volumes,
PHP settings, Apache settings, logs, health checks, and reverse-proxy setup.

## Install PHP Apex directly on a server

Install the two matching files together. The `php-zts-full` package contains
PHP 8.4 ZTS and the complete extension set. The `mod-apex` package contains
the Apache module and the `php-apex-mode` server configuration command.

The examples below download 64-bit Intel/AMD (`x86_64`/`amd64`) packages
straight from the latest GitHub release.

### Debian or Ubuntu

```bash
mkdir -p php-apex-install
cd php-apex-install
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full_8.4.21-1_amd64.deb
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex_0.1.7_amd64.deb
sudo apt install ./php-zts-full_8.4.21-1_amd64.deb ./mod-apex_0.1.7_amd64.deb
```

Switch Apache to the threaded `event` MPM and enable PHP Apex:

```bash
sudo a2dismod php8.4 mpm_prefork 2>/dev/null || true
sudo a2enmod mpm_event apex
sudo apachectl -t
sudo systemctl restart apache2
```

### Fedora

```bash
mkdir -p php-apex-install
cd php-apex-install
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.21-1.fc44.x86_64.rpm
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod_apex-0.1.7-1.fc44.x86_64.rpm
sudo dnf install ./php-zts-full-8.4.21-1.fc44.x86_64.rpm ./mod_apex-0.1.7-1.fc44.x86_64.rpm
sudo httpd -t
sudo systemctl restart httpd
```

### Arch Linux

```bash
mkdir -p php-apex-install
cd php-apex-install
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.21-1-x86_64.pkg.tar.zst
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex-0.1.7-1-x86_64.pkg.tar.zst
sudo pacman -U ./php-zts-full-8.4.21-1-x86_64.pkg.tar.zst ./mod-apex-0.1.7-1-x86_64.pkg.tar.zst
```

Then apply the configuration:

```bash
sudo httpd -t
sudo systemctl restart httpd
```

## Map PHP files to PHP Apex

Packages provide the module loader and a default PHP mapping. For a custom
virtual host, use:

```apache
<FilesMatch \.php$>
    SetHandler php-script
</FilesMatch>

DirectoryIndex index.php index.html
```

Confirm Apache is using PHP Apex and `event` MPM:

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
```

You should see `apex_module` and `mpm_event_module`. The legacy `php_module`
should not be loaded.

## Configure the server for the best performance

### Steady profile—recommended for real sites

Start here. The steady profile reads the server’s CPU count and gives Apache
64 PHP-ready workers per CPU, with a minimum of 128 and a maximum of 2,048.
It keeps worker counts proportional to the machine and favors consistent
service during busy periods.

```bash
sudo php-apex-mode steady
```

The command writes one PHP Apex performance file, validates Apache, and
restarts the correct service for Debian/Ubuntu, Fedora, or Arch.

Show the active settings at any time:

```bash
php-apex-mode status
```

If automatic CPU detection does not match the resources assigned to the
server, provide the CPU count:

```bash
sudo APEX_CPUS=4 php-apex-mode steady
```

If your PHP application uses a large amount of memory per request, choose a
smaller worker count. The supported range is 64 through 2,048:

```bash
sudo APEX_MAX_REQUEST_WORKERS=256 php-apex-mode steady
```

### Throughput profile—optional for large servers

Use the throughput profile only when the server has enough memory for a large
worker pool and receives a high volume of short requests:

```bash
sudo php-apex-mode throughput
```

This profile enables short keep-alive connections and allows up to 10,048
Apache workers. For most application servers, the CPU-sized steady profile is
the better starting point.

### Configure the performance file manually

If you prefer to manage Apache yourself, create the performance file at the
path for your distribution:

- Debian/Ubuntu: `/etc/apache2/conf-available/php-apex-performance.conf`
- Fedora: `/etc/httpd/conf.d/php-apex-performance.conf`
- Arch: `/etc/httpd/conf/conf.d/php-apex-performance.conf`

This is the steady example for a 4-CPU server:

```apache
# PHP Apex steady profile for 4 CPUs
KeepAlive Off
MaxKeepAliveRequests 10000
KeepAliveTimeout 5

<IfModule mpm_event_module>
StartServers 1
ServerLimit 4
ThreadLimit 64
ThreadsPerChild 64
MinSpareThreads 64
MaxSpareThreads 256
MaxRequestWorkers 256
MaxConnectionsPerChild 0
</IfModule>
```

On Debian or Ubuntu, enable the file once:

```bash
sudo a2enconf php-apex-performance
sudo apachectl -t
sudo systemctl restart apache2
```

On Fedora or Arch:

```bash
sudo httpd -t
sudo systemctl restart httpd
```

For a different CPU count, use `64 × CPU count` for `MaxRequestWorkers`,
round `ServerLimit` up so `ServerLimit × 64` covers that worker count, and
keep `ThreadsPerChild` and `ThreadLimit` at 64.

## OPcache settings

The packaged PHP runtime already enables OPcache and JIT. Its configuration is
stored in `/usr/local/php-zts/etc/conf.d/10-opcache.ini`.

A solid application-server starting point is:

```ini
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.jit=tracing
opcache.jit_buffer_size=128M
```

With `opcache.validate_timestamps=0`, restart Apache during deployment so
updated PHP files are loaded.

## PHP application settings

Place application-specific PHP settings in a separate INI file, for example
`/usr/local/php-zts/etc/conf.d/90-application.ini`:

```ini
memory_limit=256M
upload_max_filesize=32M
post_max_size=32M
max_execution_time=60
date.timezone=UTC
```

Restart Apache after changing PHP settings.

## If setup needs attention

Show loaded modules:

```bash
sudo apachectl -M
```

Show the PHP Apex performance profile:

```bash
php-apex-mode status
```

Show the packaged PHP runtime and extensions:

```bash
/usr/local/php-zts/bin/php -v
/usr/local/php-zts/bin/php -m
/usr/local/php-zts/bin/php --ini
```

Confirm these files exist:

```text
/usr/local/php-zts/lib/libphp.so
/usr/local/sbin/php-apex-mode
```

On Debian/Ubuntu, the module is installed at
`/usr/lib/apache2/modules/mod_apex.so`. On Fedora and Arch it is installed in
the distribution’s Apache module directory.

## Requirements

- Apache 2.4 with `event` MPM.
- The matching `php-zts-full` and `mod-apex` package pair.
- A PHP application whose third-party extensions are safe for PHP ZTS.
- Enough memory for the configured number of active PHP requests.

## License

[PolyForm Internal Use License 1.0.0](https://polyformproject.org/licenses/internal-use/1.0.0)
