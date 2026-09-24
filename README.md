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
- **Start with a conservative configuration.** The automatic profile sizes
  its PHP workers from effective CPU and memory limits, disables keep-alive,
  keeps its first PHP child persistent, checks Apache, and works across
  Debian, Ubuntu, Fedora, and Arch Linux.
- **Deploy your way.** Use the all-in-one Docker image or native packages for
  Debian, Ubuntu, Fedora, and Arch Linux.

## PHP Apex compared with the usual choices

| | PHP Apex | PHP-FPM | Legacy mod_php |
| --- | --- | --- | --- |
| Request path | Apache runs PHP directly | Apache proxies to FastCGI | Apache runs PHP directly |
| Apache MPM | `event` | `event` | Usually `prefork` |
| PHP runtime | Thread-safe PHP ZTS | Separate PHP processes | PHP inside Apache processes |
| Services to operate | One web service | Apache plus PHP-FPM | One web service |
| Worker tuning | Conservative and throughput profiles included | Tune Apache and FPM pools | Tune prefork Apache |
| Ready-to-run container | Apache, PHP, and PHP Apex together | Commonly split or supervised | Available, but tied to prefork |

PHP Apex is a strong fit when Apache is part of your platform and you want a
direct PHP execution model without giving up the event MPM. It is especially
useful for containerized PHP applications, dedicated application servers, and
teams that want fewer moving parts between the web server and PHP.

An earlier local PHP microbenchmark found PHP Apex faster than PHP-FPM
**especially with HTTP keep-alive enabled**. On the same small PHP script, with
Apache `event` MPM, PHP 8.4 ZTS, and OPcache, Apex delivered 33.9%–52.2% more
requests per second across 100–1,000 connections. At 300 connections, it
served 41,429 req/s versus PHP-FPM's 27,573 req/s. With keep-alive disabled at
100 connections, the results were nearly equal (9,820 versus 9,987 req/s).
These historical results are from one machine and a synthetic workload; they
are not a PHP-FPM comparison for the current WordPress production baseline.

## Security compared with legacy mod_php

PHP Apex ships with several defensive defaults that an unconfigured legacy
mod_php deployment may lack. The module returns a generic fatal-error page
unless `ApexVerboseErrors` is explicitly enabled. It refuses to execute a PHP
path with the wrong handler mapping or a target that is not a regular file, and
it catches PHP startup failures so they return an error instead of taking down
the Apache child. Its build script requests stack protection, fortified libc
calls, format-string checks, and linker hardening.

The supplied Docker image suppresses PHP and Apache version strings in response
headers, disables HTTP TRACE and directory indexes, restricts `.htaccess`
overrides to rewrite directives, and defaults session cookies to `HttpOnly` and
`SameSite=Lax`. Its runtime stage omits the compiler toolchain and development
headers, and its sample PHP test page stays
outside the document root unless explicitly enabled. A read-only application
mount is supported. Operators can also opt into disabling command-execution
functions and URL-aware file wrappers; **neither restriction is enabled by
default** because applications may need them. Disabling URL-aware file wrappers
does not block other HTTP clients such as cURL. See
[Docker security controls](#docker-security-controls) for the image settings.

These are configuration and build safeguards, **not a process-isolation
advantage**. Like mod_php, PHP Apex runs application code inside Apache workers
with the worker's operating-system privileges. A hardened mod_php deployment
can use comparable controls. A read-only mount or a reduced runtime image does
not sandbox PHP; use separate processes or containers when you need isolation
between applications or untrusted tenants.

## Measured production baseline

The current production gate runs an uncached WordPress workload in a container
limited to exactly 2 CPUs and 2 GiB of memory. PHP Apex automatic tuning selected
4 workers, disabled keep-alive, and left worker recycling unlimited. The test
used Apache `event` MPM, PHP 8.4.25 ZTS, OPcache, and tracing JIT.

| Measurement | 60-second baseline | 30-minute soak |
| --- | ---: | ---: |
| Concurrency | 64 | 64 |
| Completed requests | 2,401 | 73,148 |
| Failed requests | 0 | 0 |
| Throughput | 40.02 req/s | 40.64 req/s |
| Median latency | 1.616 s | 1.682 s (worst segment) |
| p99 latency | 1.772 s | 1.874 s (worst segment) |
| Container restarts | 0 | 0 |
| OOM events | 0 | 0 |

The soak was recorded as two contiguous ApacheBench segments because of the
client's request-count limit. Across the combined 1,800 seconds, throughput was
1.5% above the short baseline and worst-segment p99 latency increased by 5.8%.
The container remained healthy with no crash signatures.

### Memory efficiency at the production baseline

These values are cgroup measurements for the complete Apache and PHP Apex
container, not the RSS of an individual thread:

| Resource | Measured result |
| --- | ---: |
| Container memory limit | 2,048 MiB |
| Automatically configured PHP workers | 4 |
| Warmed memory before the soak | 216.9 MiB |
| Peak memory during the soak | 221.5 MiB |
| Memory after the soak | 134.4 MiB |
| Headroom at peak | 1,826.5 MiB (89.2%) |

No current PHP-FPM run has been measured under the same 2-CPU, 2-GiB limits,
worker count, application state, and traffic. The figures above therefore show
that the current Apex profile is stable and comfortably inside its memory
budget; they do not establish that Apex uses less memory than PHP-FPM.

### JIT decision

A separate 60-second WordPress test at concurrency 16 compared tracing JIT
with JIT disabled. Tracing JIT was retained because it increased throughput by
about 10% and improved tail latency on this workload.

| Measurement | Tracing JIT, 128 MiB | JIT disabled |
| --- | ---: | ---: |
| Completed requests | 2,380 | 2,164 |
| Failed requests | 0 | 0 |
| Throughput | 39.66 req/s | 36.04 req/s |
| Median latency | 411 ms | 474 ms |
| p99 latency | 487 ms | 507 ms |
| Maximum latency | 501 ms | 568 ms |

All benchmark results are from one machine and are not guarantees for every
application. Database calls, application code, network latency, extensions,
CPU limits, and memory limits all affect real-world results.

## Recommended: launch the all-in-one image

Get Apache, PHP 8.4 ZTS, PHP Apex, OPcache, health checks, the conservative
worker profile, and the full extension set in one image. Bring your application
and set the container limits; the request stack is already assembled.

```bash
mkdir -p "$PWD/public"
test -e "$PWD/public/healthz" || printf 'ok\n' > "$PWD/public/healthz"
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

Mounting an application over `/var/www/html` also hides files supplied there
by the image, including the built-in `/healthz`. The example creates a static
replacement in the mounted document root so Docker's health check keeps
working. Alternatively, build a derived image with
`COPY public/ /var/www/html/`; copying the application preserves the health file
unless the application replaces it.

For production, set CPU and memory limits outside the image:

```bash
if [ ! -e /srv/my-app/public/healthz ]; then
  printf 'ok\n' | sudo tee /srv/my-app/public/healthz >/dev/null
fi
docker run -d \
  --name php-apex \
  --restart unless-stopped \
  --cpus=2 \
  --memory=2g \
  -p 8080:80 \
  -v /srv/my-app/public:/var/www/html:ro \
  practicalwebuser/mod_apex-apache:php8.4
```

The image automatically sizes its worker pool from its CPU and memory limits,
disables keep-alive, and keeps the first child persistent. See [DOCKER.md](DOCKER.md) for application volumes,
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
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full_8.4.25-1_amd64.deb
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex_0.1.9_amd64.deb
sha256sum --ignore-missing -c SHA256SUMS
sudo apt install ./php-zts-full_8.4.25-1_amd64.deb ./mod-apex_0.1.9_amd64.deb
```

Switch Apache to the threaded `event` MPM, enable PHP Apex, and apply the
automatic resource-aware settings:

```bash
sudo a2dismod php8.4 2>/dev/null || true
sudo a2disconf php8.4-fpm 2>/dev/null || true
sudo a2dismod mpm_prefork 2>/dev/null || true
sudo a2enmod mpm_event apex
sudo apachectl -t
sudo systemctl restart apache2
sudo php-apex-mode auto
```

### Fedora

```bash
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.25-1.fc44.x86_64.rpm
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod_apex-0.1.9-1.fc44.x86_64.rpm
sha256sum --ignore-missing -c SHA256SUMS
sudo dnf install ./php-zts-full-8.4.25-1.fc44.x86_64.rpm ./mod_apex-0.1.9-1.fc44.x86_64.rpm
sudo httpd -t
sudo systemctl enable httpd
sudo php-apex-mode auto
```

### Arch Linux

```bash
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/php-zts-full-8.4.25-1-x86_64.pkg.tar.zst
curl -fLO https://github.com/apache-modules/mod-apex/releases/latest/download/mod-apex-0.1.9-1-x86_64.pkg.tar.zst
sha256sum --ignore-missing -c SHA256SUMS
sudo pacman -U ./php-zts-full-8.4.25-1-x86_64.pkg.tar.zst ./mod-apex-0.1.9-1-x86_64.pkg.tar.zst
```

Enable Apache at boot and apply the automatic settings:

```bash
sudo httpd -t
sudo systemctl enable httpd
sudo php-apex-mode auto
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
sudo php-apex-mode auto
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

### Automatic profile—recommended default

Start here. New native packages run this profile during installation. It uses
twice the effective CPU count as the CPU budget and reserves 25% of memory
(at least 256 MiB), budgeting 128 MiB for each active PHP worker. The lower
budget wins. A 2-CPU, 2-GiB server therefore starts with four workers; this
host's 16 CPUs and 7.5 GiB select 32. Keep-alive remains disabled.

> **Important:** let `php-apex-mode auto` own the event-MPM worker settings.
> Do not manually change `ServerLimit`, `ThreadLimit`, `ThreadsPerChild`, or
> `MaxRequestWorkers` independently. These directives must form one valid
> layout; a mismatch can make Apache silently raise or lower the effective
> worker count, increasing memory use or reducing performance. Run automatic
> tuning again after changing the server's CPU or memory allocation.

```bash
sudo php-apex-mode auto
```

The command writes one PHP Apex performance file, validates Apache, and
restarts the correct service for Debian/Ubuntu, Fedora, or Arch.

Show the active settings at any time:

```bash
php-apex-mode status
```

If measurement supports a different limit, choose 1 through 512 workers:

```bash
sudo APEX_MAX_REQUEST_WORKERS=8 php-apex-mode auto
```

### Throughput profile—optional for large servers

Use the throughput profile when the server has enough memory and receives a
high volume of short requests:

```bash
sudo php-apex-mode throughput
```

This profile enables short keep-alive connections and raises the controlled
worker pool to 256. It retains the 1,000-connection recycling limit. The
automatic profile remains the recommended starting point.

### Advanced: configure the performance file manually

Manual configuration is intended only for operators who have measured their
application and understand Apache event-MPM sizing. Prefer
`sudo php-apex-mode auto`. If you must manage Apache yourself, create the
performance file at the path for your distribution:

- Debian/Ubuntu: `/etc/apache2/conf-available/php-apex-performance.conf`
- Fedora: `/etc/httpd/conf.d/php-apex-performance.conf`
- Arch: `/etc/httpd/conf/conf.d/php-apex-performance.conf`

This is the safe fallback installed before automatic sizing runs on a
2-CPU, 2-GiB server:

```apache
# PHP Apex automatically sized fallback
KeepAlive Off
MaxKeepAliveRequests 10000
KeepAliveTimeout 1

<IfModule mpm_event_module>
StartServers 1
ServerLimit 1
ThreadLimit 4
ThreadsPerChild 4
MinSpareThreads 4
MaxSpareThreads 4
MaxRequestWorkers 4
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

For a different worker count, ensure `MaxRequestWorkers` exactly equals
`ServerLimit × ThreadsPerChild`, with `ThreadLimit` equal to
`ThreadsPerChild`. Apache otherwise silently reduces `MaxRequestWorkers` to a
valid multiple. `php-apex-mode` calculates this layout for you, keeping at
most 64 threads per child and eight children.

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
updated PHP files are loaded. This setting is best when application code is
immutable.

The Docker image uses the same immutable-code default. If PHP files can change
inside a running container—for example, WordPress writes a plugin or theme to
a mounted volume—start the container with:

```bash
docker run -d \
  -e APEX_OPCACHE_VALIDATE=1 \
  -p 8080:80 \
  -v "$(pwd)/app:/var/www/html" \
  practicalwebuser/mod_apex-apache:php8.4
```

Use `APEX_OPCACHE_VALIDATE=0` for baked-in or read-only code and `1` for
writable PHP code. The container rejects any other value during startup.

## Apache and Docker security controls

The Docker image generates these safer PHP defaults at startup:

```ini
expose_php=Off
session.cookie_httponly=1
session.cookie_samesite=Lax
```

It also enables Apache's `mod_headers` and applies these response-header
defaults to successful and error responses:

```text
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
```

Apache removes `X-Powered-By` as a defense in depth measure in addition to
PHP's `expose_php=Off`. The Debian, Fedora, and Arch packages install the same
policy as `php-apex-security.conf`, and the example [httpd.conf](httpd.conf)
contains the same defaults. CSP, HSTS, `X-Frame-Options`, Permissions Policy,
and CORS examples remain commented out in
[docker/security-hardening.conf](docker/security-hardening.conf) and
`httpd.conf`: those policies depend on the application's resource origins,
embedding requirements, browser features, TLS termination, and allowed
cross-origin callers. Review them for the deployed site before enabling them;
never enable HSTS on an HTTP-only endpoint.

For a multi-tenant platform that accepts customer PHP code, opt into stricter
process and remote-file access:

```bash
docker run -d \
  -e APEX_DISABLE_FUNCTIONS=exec,passthru,shell_exec,system,proc_open,popen \
  -e APEX_ALLOW_URL_FOPEN=0 \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

The function list is empty by default because legitimate applications may use
`proc_open`. It must be a comma-separated list of PHP function names.
`APEX_ALLOW_URL_FOPEN` accepts `0` or `1` and defaults to `1`.

The image does not expose `/test.php` by default. Set
`APEX_ENABLE_TEST_PAGE=1` only for a temporary private smoke test. The
entrypoint overwrites `/var/www/html/test.php`, so the path must not contain an
application file you need to preserve. Because the option requires a writable
document root, it fails with the read-only bind mount shown above. On a
writable host mount, disabling the variable does not remove the generated
file: delete `test.php` from the mounted content and remove the setting before
public exposure. For a read-only mount, provide a private application probe in
the mounted content instead.

When the container runs behind a trusted reverse proxy, set its network CIDR
so PHP receives the resolved visitor address in `REMOTE_ADDR`:

```bash
docker run -d \
  -e APEX_TRUSTED_PROXY="10.89.0.0/16" \
  -p 8080:80 \
  practicalwebuser/mod_apex-apache:php8.4
```

Multiple addresses or CIDRs may be space-separated. Trust only networks that
cannot be reached directly by untrusted clients. For proxy chains, every hop
must validate and sanitize the forwarded header or be explicitly trusted.

The container uses `AllowOverride All` so the standard `.htaccess` files from
WordPress, Drupal, and Symfony work without image-specific rewrites. For a
controlled production deployment, move the application's rules into the
virtual-host configuration and set `AllowOverride None` for tighter control
and to avoid per-request `.htaccess` discovery. `mod_apex` registers no
`php_value` or `php_admin_value` directive; use `php.ini` or a mounted INI file
for PHP settings. `disable_functions` is not a tenant sandbox.

`APEX_MAX_CONNECTIONS_PER_CHILD` controls Apache child recycling and defaults
to `0`, which keeps the single baseline child persistent. It counts TCP
connections rather than requests. Multi-child deployments can test `1000` or
`10000` while observing memory, restarts, throughput, and latency.

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
`php-apex-mode auto`, and let Apache serve PHP directly through its event
workers.

## License

PHP Apex is licensed under the [GPL-3.0](LICENSE). See
[NOTICE](NOTICE) for the required attribution notices.

PHP, Apache HTTP Server, and bundled extensions remain under their respective
licenses. Binary packages and container images include software from those
projects; review their accompanying notices when redistributing an image or
package.
