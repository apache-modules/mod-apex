# PHP Apex for Apache

**One web server. One request path. PHP ready inside Apache.**

PHP Apex runs PHP directly in Apache's modern `event` MPM workers. It removes
the PHP-FPM proxy layer, FastCGI socket, separate process pool, and second
request queue—without sending Apache back to the legacy prefork model used by
traditional mod_php.

Choose the ready-to-run Docker image or install matching packages on Debian,
Ubuntu, Fedora, or Arch Linux.

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
```

## Stop running two systems to serve one PHP request

A typical Apache and PHP-FPM stack asks you to operate two services. Apache
accepts the request, forwards it through FastCGI, and waits for a separate PHP
worker pool. That means two sets of workers, two places to tune capacity, and
another boundary to monitor.

PHP Apex gives Apache a thread-safe PHP runtime of its own. Apache receives the
request and executes the PHP file in the same worker thread. Your application
still gets PHP 8.4, OPcache, popular extensions, Apache configuration, virtual
hosts, access control, and the event MPM—through a shorter, simpler path.

## Why PHP Apex

- **Operate less infrastructure.** No PHP-FPM service, FastCGI socket, or
  separate PHP worker pool to deploy and keep in sync.
- **Keep modern Apache.** PHP Apex is built for the threaded `event` MPM, not
  the connection-heavy prefork model required by legacy mod_php.
- **Keep PHP ready.** Every Apache worker thread owns a persistent PHP ZTS
  runtime for incoming PHP requests.
- **Start with the extensions applications expect.** OPcache, JIT, APCu,
  Redis, Imagick, MySQL, SQLite, GD, intl, mbstring, ZIP, sodium, SOAP, and
  more are included in the full runtime.
- **Size the server in one command.** `php-apex-mode steady` reads the CPU
  count, writes the Apache worker settings, checks the configuration, and
  restarts the correct service.
- **Deploy your way.** Use the all-in-one Docker image or native packages for
  Debian, Ubuntu, Fedora, and Arch Linux.

## PHP Apex compared with the usual choices

| | PHP Apex | PHP-FPM | Legacy mod_php |
| --- | --- | --- | --- |
| Request path | Apache runs PHP directly | Apache proxies to FastCGI | Apache runs PHP directly |
| Apache MPM | `event` | `event` | Usually `prefork` |
| PHP runtime | Thread-safe PHP ZTS | Separate PHP processes | PHP inside Apache processes |
| Services to operate | One web service | Apache plus PHP-FPM | One web service |
| Worker tuning | CPU-aware helper included | Tune Apache and FPM pools | Tune prefork Apache |
| Ready-to-run container | Apache, PHP, and PHP Apex together | Commonly split or supervised | Available, but tied to prefork |

PHP Apex is a strong fit when Apache is part of your platform and you want a
direct PHP execution model without giving up the event MPM. It is especially
useful for containerized PHP applications, dedicated application servers, and
teams that want fewer moving parts between the web server and PHP.

## Measured PHP performance

These local tests used an AMD Ryzen 7 PRO 6850U, Apache `event` MPM, PHP 8.4
ZTS, OPcache, and the same small PHP script for PHP Apex and PHP-FPM. They show
why persistent connections matter as traffic increases.

With keep-alive disabled at 100 connections, both handlers delivered about the
same throughput:

| Handler | Requests per second |
| --- | ---: |
| PHP Apex | 9,820 |
| PHP-FPM | 9,987 |

With keep-alive enabled, PHP Apex avoided the FastCGI handoff and pulled ahead
at every tested connection level:

| Connections | PHP Apex | PHP-FPM | PHP Apex advantage |
| ---: | ---: | ---: | ---: |
| 100 | 38,697 req/s | 28,903 req/s | 33.9% |
| 300 | 41,429 req/s | 27,573 req/s | 50.2% |
| 500 | 37,985 req/s | 26,273 req/s | 44.6% |
| 1,000 | 37,536 req/s | 24,664 req/s | 52.2% |

At 300 connections, measured p99 latency was 51.74 ms for PHP Apex and
79.55 ms for PHP-FPM. At 1,000 connections, it was 279.96 ms for PHP Apex and
310.14 ms for PHP-FPM.

These are results from one machine running a simple local workload, not a
guarantee for every application. Database calls, application code, network
latency, extensions, CPU limits, and memory limits all affect real-world
results. Run your own application under representative traffic before choosing
production capacity.

## Recommended: launch the all-in-one image

Get Apache, PHP 8.4 ZTS, PHP Apex, OPcache, health checks, automatic worker
sizing, and the full extension set in one image. Bring your application and
set the container limits; the request stack is already assembled.

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
straight from the latest GitHub release. Run these commands as a user with
`sudo` access. If Apache already sends `.php` files to mod_php or PHP-FPM,
disable that PHP handler before enabling PHP Apex.

Create a clean download directory first:

```bash
mkdir -p php-apex-install
cd php-apex-install
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/SHA256SUMS
```

### Debian or Ubuntu

```bash
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full_8.4.21-1_amd64.deb
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex_0.1.7_amd64.deb
sha256sum --ignore-missing -c SHA256SUMS
sudo apt install ./php-zts-full_8.4.21-1_amd64.deb ./mod-apex_0.1.7_amd64.deb
```

Switch Apache to the threaded `event` MPM, enable PHP Apex, and apply the
recommended CPU-sized settings:

```bash
sudo a2dismod php8.4 2>/dev/null || true
sudo a2disconf php8.4-fpm 2>/dev/null || true
sudo a2dismod mpm_prefork 2>/dev/null || true
sudo a2enmod mpm_event apex
sudo apachectl -t
sudo systemctl restart apache2
sudo php-apex-mode steady
```

### Fedora

```bash
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.21-1.fc44.x86_64.rpm
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod_apex-0.1.7-1.fc44.x86_64.rpm
sha256sum --ignore-missing -c SHA256SUMS
sudo dnf install ./php-zts-full-8.4.21-1.fc44.x86_64.rpm ./mod_apex-0.1.7-1.fc44.x86_64.rpm
sudo httpd -t
sudo systemctl enable httpd
sudo php-apex-mode steady
```

### Arch Linux

```bash
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.21-1-x86_64.pkg.tar.zst
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex-0.1.7-1-x86_64.pkg.tar.zst
sha256sum --ignore-missing -c SHA256SUMS
sudo pacman -U ./php-zts-full-8.4.21-1-x86_64.pkg.tar.zst ./mod-apex-0.1.7-1-x86_64.pkg.tar.zst
```

Enable Apache at boot and apply the recommended CPU-sized settings:

```bash
sudo httpd -t
sudo systemctl enable httpd
sudo php-apex-mode steady
```

### Verify the server installation

Use the same checks on Debian, Ubuntu, Fedora, or Arch:

```bash
sudo apachectl -t
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
/usr/local/php-zts/bin/php -r 'echo PHP_VERSION, " ", PHP_ZTS ? "ZTS\n" : "NTS\n";'
php-apex-mode status
```

Apache should report `Syntax OK`. The module list should contain
`apex_module` and `mpm_event_module`, but not the legacy `php_module`. PHP
should report version 8.4 and `ZTS`. The final command shows the active worker
profile.

The quickest check that the installed PHP runtime is the required thread-safe
build is:

```bash
/usr/local/php-zts/bin/php -r 'echo PHP_ZTS ? "PHP ZTS is loaded\n" : "PHP is not ZTS\n";'
```

The expected result is `PHP ZTS is loaded`.

Create a PHP file in your virtual host's document root and request it through
Apache to confirm the complete request path:

```php
<?php
echo "PHP Apex is running\n";
```

Remove that check file after verification.

### Upgrade PHP Apex

Download the new matching `php-zts-full` and `mod-apex` files from the same
release, verify them with that release's `SHA256SUMS`, and install both files
together using the same `apt`, `dnf`, or `pacman -U` command shown above.
Never mix the PHP runtime from one release with the module from another.

After an upgrade, reapply and verify the profile:

```bash
sudo php-apex-mode steady
sudo apachectl -t
```

### Remove PHP Apex

Remove the Apache module first. Remove `php-zts-full` too only when no other
installed software uses that runtime.

Debian or Ubuntu:

```bash
sudo apt remove mod-apex
sudo apt remove php-zts-full
```

Fedora:

```bash
sudo dnf remove mod_apex
sudo dnf remove php-zts-full
```

Arch Linux:

```bash
sudo pacman -R mod-apex
sudo pacman -R php-zts-full
```

## Map PHP files to PHP Apex

Edit the virtual-host file for your site:

- Debian/Ubuntu: `/etc/apache2/sites-available/YOUR-SITE.conf`
- Fedora: `/etc/httpd/conf.d/YOUR-SITE.conf`
- Arch: `/etc/httpd/conf/conf.d/YOUR-SITE.conf`

Replace `YOUR-SITE` with the site name. Put this mapping inside that virtual
host's `<VirtualHost>` block so `.php` files are handled by PHP Apex:

```apache
<FilesMatch \.php$>
    SetHandler php-script
</FilesMatch>

DirectoryIndex index.php index.html
```

For example, a Debian or Ubuntu site might contain:

```apache
<VirtualHost *:80>
    ServerName example.com
    DocumentRoot /var/www/example/public

    <FilesMatch \.php$>
        SetHandler php-script
    </FilesMatch>

    DirectoryIndex index.php index.html
</VirtualHost>
```

On Debian or Ubuntu, enable a newly created site before restarting Apache:

```bash
sudo a2ensite YOUR-SITE.conf
sudo apachectl -t
sudo systemctl restart apache2
```

On Fedora or Arch, files in the directories shown above are loaded
automatically:

```bash
sudo httpd -t
sudo systemctl restart httpd
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

## Put PHP on the shortest path through Apache

Start with the all-in-one image:

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
```

Prefer a native server installation? Use the matching packages above, run
`php-apex-mode steady`, and let Apache serve PHP directly through its event
workers.

## License

PHP Apex is licensed under the [Apache License 2.0](LICENSE). You may use,
modify, and redistribute it under that license. Modified files must be clearly
identified, and the required copyright, license, and attribution notices must
be retained.

The Apache License 2.0 does not grant permission to use the PHP Apex product
name or branding to imply that a modified or third-party build is an official
release or is endorsed by the PHP Apex maintainers. Descriptive references to
the project's origin remain permitted by the license.

PHP, Apache HTTP Server, and bundled extensions remain under their respective
licenses. Binary packages and container images include software from those
projects; review their accompanying notices when redistributing an image or
package.
