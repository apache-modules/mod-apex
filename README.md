# PHP Apex

**Run PHP inside Apache. Skip FastCGI. Keep the event MPM.**

PHP Apex is powered by `mod_apex`, an Apache module that embeds a persistent
PHP ZTS runtime in each Apache worker thread.
Apache accepts the request and runs PHP in the same thread. There is no
FastCGI socket, no separate FPM queue, and no legacy prefork requirement.

```text
PHP-FPM: client -> Apache -> FastCGI proxy -> FPM worker -> PHP
mod_apex: client -> Apache worker -> PHP
```

Try it without changing your server:

```bash
docker build -t mod-apex .
docker run --rm -d --name mod-apex-demo -p 8080:80 mod-apex
curl -sS http://127.0.0.1:8080/test.php
docker stop mod-apex-demo
```

Expected output:

```text
OK
sapi=apache2handler
```

## Why PHP Apex

- **More direct than PHP-FPM.** PHP runs in the Apache request thread. No
  FastCGI proxy hop. No second request queue.
- **Modern replacement for mod_php.** PHP ZTS runs with Apache's threaded
  `event` MPM. Legacy mod_php normally forces `prefork`.
- **Lower latency under load.** Removing the FPM boundary reduces queueing
  and keeps tail latency tighter as concurrency rises.
- **Fewer services to operate.** No FPM pool to size, monitor, or restart.
- **Working OPcache and JIT.** mod_apex uses the `apache2handler` SAPI name
  so PHP's OPcache allowlist accepts the embedded runtime.

### Measured against PHP-FPM

Local test: 16-thread AMD Ryzen 7 PRO 6850U, Apache event MPM, PHP 8.4 ZTS,
OPcache enabled, keep-alive enabled, identical PHP scripts.

| Connections | mod_apex | PHP-FPM | mod_apex result |
| ---: | ---: | ---: | ---: |
| 100 | 38,697 req/s | 28,903 req/s | 33.9% more req/s |
| 300 | 41,429 req/s | 27,573 req/s | 50.2% more req/s |
| 500 | 37,985 req/s | 26,273 req/s | 44.6% more req/s |
| 1,000 | 37,536 req/s | 24,664 req/s | 52.2% more req/s |

At 300 connections, p99 latency was 51.74 ms for mod_apex and 79.55 ms for
FPM. At 1,000 connections, p99 was 279.96 ms for mod_apex and 310.14 ms for
FPM. Results depend on workload and hardware. Test your application. The
repeatable design advantage is the missing proxy and pool hop, not a promise
that every application gains 50% throughput.

### Pick the right runtime

| Option | Request path | Apache MPM | Best reason to use it | Tradeoff |
| --- | --- | --- | --- | --- |
| mod_apex | Apache thread runs PHP | `event` | Direct path, low latency, one service | Requires PHP ZTS and thread-safe extensions |
| PHP-FPM | Apache proxies to FPM | `event` | Process isolation and independent pool scaling | Proxy hop, second queue, second service |
| mod_php | Apache process runs PHP | Usually `prefork` | Familiar legacy setup | Older concurrency model and higher process memory |

Choose mod_apex when you control the PHP build, need Apache, and want the
shortest request path. Choose FPM when process isolation matters more than
latency. Never load non-thread-safe PHP or extensions into mod_apex.

## Features

- PHP stays ready inside Apache, so each request avoids a separate PHP service.
- OPcache + JIT enabled and working (packaged builds ship JIT on by default:
  `tracing` mode, 128M buffer).
- Broad bundled extension set: APCu, Redis, Imagick, mbstring,
  intl, zip, bcmath, soap, GD, sodium, gmp, curl, openssl, zlib, sqlite3,
  PDO (sqlite3/mysqli), exif, and xsl. Verify every application's third-party
  extensions are ZTS-safe before deployment.
- Ships as a Docker image, Debian/Ubuntu `.deb` pair, or Fedora RPM pair.
- Production-conscious defaults: generic (non-leaking) fatal-error pages,
  with an opt-in `ApexVerboseErrors` for local debugging.

## Requirements

- Apache 2.4 with the threaded `event` MPM.
- The matching `php-zts-full` package supplied with mod_apex.
- Enough memory for your PHP application and its active requests.

## License

[PolyForm Internal Use License 1.0.0](https://polyformproject.org/licenses/internal-use/1.0.0)
-- free to use and modify internally, redistribution not permitted -- see
[LICENSE](LICENSE).

## Install PHP Apex on your server

Use the two matching packages supplied with mod_apex. They include PHP and
the mod_apex Apache module, so you do not need to build PHP or compile C code.

### Debian or Ubuntu

Copy both `.deb` files to the server, then run:

```bash
sudo dpkg -i php-zts-full_*.deb
sudo apt-get -f install
sudo a2dismod php8.4 || true
sudo a2disconf php8.4-fpm || true
sudo a2dismod mpm_prefork || true
sudo a2enmod mpm_event
sudo dpkg -i mod-apex_*.deb
```

Replace `php8.4` with your installed distro PHP version if it differs.

### Fedora

Copy both RPM files to the server, then run:

```bash
sudo dnf install php-zts-full-*.rpm
sudo dnf install mod_apex-*.rpm
```

Fedora calls Apache `httpd` rather than `apache2`. Use `httpd` in the service
commands below.

### Quick local test with Docker or Podman

Want to see mod_apex before changing a server? Build and run the included
image:

```bash
docker pull practicalwebuser/mod_apex-apache:php8.4
docker run --rm -d --name mod-apex-demo -p 8080:80 practicalwebuser/mod_apex-apache:php8.4
curl -sS http://127.0.0.1:8080/test.php
docker stop mod-apex-demo
```

Use `podman` instead of `docker` if that is what your server uses.
For application mounts, resource limits, reverse-proxy setup, and tuning,
read [DOCKER.md](DOCKER.md).

## Set up Apache

### 1. Make Apache use mod_apex for PHP

The install commands above turn off the old PHP handler and turn on Apache's
modern request mode. Run these again only if another package has turned the
old handler back on:

```bash
sudo a2dismod php8.4 || true          # match your installed PHP version
sudo a2disconf php8.4-fpm || true
sudo a2dismod mpm_prefork || true
sudo a2enmod mpm_event
sudo systemctl disable --now php8.4-fpm || true
```

Verify only mod_apex is serving PHP afterward:

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
# expect: apex_module and mpm_event_module present, php_module absent
```

### 2. Map PHP requests

Add this to the vhost or an enabled Apache configuration file:

```apache
<FilesMatch \.php$>
    SetHandler php-script
</FilesMatch>

<IfModule apex_module>
    ApexVerboseErrors Off
</IfModule>
```

### 3. Validate, restart, test

These commands use Debian/Ubuntu names and the default document root. On
Fedora, substitute `httpd` for `apache2`/`apachectl`. Adjust `/var/www/html`
if your vhost uses another document root.

```bash
sudo apachectl -t
sudo systemctl restart apache2
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
sudo install -m 0644 test.php /var/www/html/apex-smoke.php
curl -sS http://127.0.0.1/apex-smoke.php
sudo rm /var/www/html/apex-smoke.php
```

Expected modules: `apex_module` and `mpm_event_module`. `php_module` must not
be loaded. Expected request output:

```text
OK
sapi=apache2handler
```

## Settings and performance modes

Do not copy giant numbers from the internet. Start with the steady profile,
then check that your site stays fast and has enough memory.

### Throughput mode

Persistent connections provide maximum requests per second in this test.

The included profile is a stress-test preset, not a universal production
default. It allows 10,048 Apache workers and can reserve substantial memory
because every worker thread can execute PHP. Use it only on a host sized for
that concurrency; otherwise copy the keep-alive ideas and choose a measured
`MaxRequestWorkers` value for your application.

```bash
sudo cp /etc/apache2/apache2.conf \
  /etc/apache2/apache2.conf.before-apex-throughput
sudo cp /etc/apache2/mods-enabled/mpm_event.conf \
  /etc/apache2/mods-enabled/mpm_event.conf.before-apex-throughput
sudo ./tools/apache_mode.sh throughput
```

The tool replaces selected keep-alive and event-MPM values. Back up custom
configuration first, as shown above. To restore it:

```bash
sudo cp /etc/apache2/apache2.conf.before-apex-throughput \
  /etc/apache2/apache2.conf
sudo cp /etc/apache2/mods-enabled/mpm_event.conf.before-apex-throughput \
  /etc/apache2/mods-enabled/mpm_event.conf
sudo apachectl -t
sudo systemctl restart apache2
```

Core keep-alive settings:

```apache
KeepAlive On
MaxKeepAliveRequests 10000
KeepAliveTimeout 1
```

On the benchmark host, throughput mode raised mod_apex from about 9.8k to
38-41k requests/s. Profiling showed that connection and kernel work dominated
when keep-alive was disabled.

### Steady mode: the sensible starting point

Use this when you want a smooth, dependable starting point. It is made for
real sites, not leaderboard benchmarks:

```bash
sudo ./tools/apache_mode.sh steady
```

It looks at your server's CPU count and picks a sensible number of PHP-ready
Apache workers. Small servers get at least 128 workers. Large servers stop at
2,048 by default, so one command does not accidentally turn a big machine
into a memory hog.

If a container reports the wrong CPU count, or your PHP app needs more memory
per request, you can choose the number yourself:

```bash
sudo APEX_CPUS=4 ./tools/apache_mode.sh steady
sudo APEX_MAX_REQUEST_WORKERS=256 ./tools/apache_mode.sh steady
```

Steady mode favors a calm server over the biggest possible benchmark number.
It does not restore previous custom settings. Show current values:

```bash
./tools/apache_mode.sh status
```

### Apache event MPM

`MaxRequestWorkers` must fit CPU and memory. Keep these relationships valid:

```text
MaxRequestWorkers <= ServerLimit * ThreadsPerChild
MaxSpareThreads <= MaxRequestWorkers
```

More threads do not create more CPU. Raise counts only after observing worker
exhaustion, queueing, and available memory.

### A working starting setup

This is the short version: Apache uses the modern `event` mode, mod_apex runs
PHP directly inside Apache, and detailed PHP crash pages stay off for visitors.

```apache
# Load PHP first, then mod_apex.
LoadFile /usr/local/php-zts/lib/libphp.so
LoadModule apex_module /usr/lib/apache2/modules/mod_apex.so

<IfModule mpm_event_module>
    ThreadLimit 64
    ThreadsPerChild 64
</IfModule>

<FilesMatch \.php$>
    SetHandler php-script
</FilesMatch>

<IfModule apex_module>
    ApexVerboseErrors Off
</IfModule>
```

Then let mod_apex choose the matching Apache worker settings:

```bash
sudo ./tools/apache_mode.sh steady
sudo apachectl -t
```

This is a clean route from web request to PHP: no FastCGI socket, no second
PHP service, and no extra request queue to manage.

### 1,000-connection example

On the local benchmark machine, mod_apex served the same PHP page with these
results. `Read errors` are `wrk` client-side read errors, not PHP application
errors.

| `wrk` threads | Requests/second | Read errors |
| ---: | ---: | ---: |
| 2 | 37,552 | 5,094 |
| 4 | 37,536 | 319 |
| 8 | 35,782 | **0** |
| 16 | 32,091 | 10 |

The sweet spot here was 8 `wrk` threads: **35,782 requests per second with
zero read errors** at 1,000 connections. Your best number will depend on your
CPU, network, PHP code, and load-generator machine. Start with 8 client
threads for a 1,000-connection local test, then test your own app.

### OPcache

Production starting point:

Put these directives in the ZTS build's scanned INI directory (the packaged
default is `/usr/local/php-zts/etc/conf.d/10-opcache.ini`):

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

With `opcache.validate_timestamps=0`, restart/reload Apache or call
`opcache_reset()` during deployment. Confirm `php_sapi_name()` returns
`apache2handler` and `opcache_get_status(false)` does not return `false`.

Verify from a web request, because the CLI can use a different SAPI and INI:

```bash
sudo tee /var/www/html/apex-opcache-check.php >/dev/null <<'PHP'
<?php
header('Content-Type: text/plain');
echo 'sapi=' . php_sapi_name() . PHP_EOL;
echo 'opcache=' . (opcache_get_status(false) !== false ? 'on' : 'off') . PHP_EOL;
PHP
curl -sS http://127.0.0.1/apex-opcache-check.php
sudo rm /var/www/html/apex-opcache-check.php
```

Expected: `sapi=apache2handler` and `opcache=on`. Adjust the document root
for your vhost.

JIT helps numeric workloads more than typical CMS code. Benchmark JIT on and
off before treating it as required.

### Linux limits

Raise Apache's file-descriptor limit:

```bash
sudo systemctl edit apache2
```

Add:

```ini
[Service]
LimitNOFILE=65535
```

For thousands of connections, test these host limits:

```bash
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sudo systemctl daemon-reload
sudo systemctl restart apache2
```

These are host-wide settings. Change them only after measurement shows a
listen or SYN backlog limit; they do not increase PHP execution capacity.

Persist successful `sysctl` values in `/etc/sysctl.d/`; command-line values
do not survive reboot.

### Load testing

Check response correctness before measuring speed:

```bash
sudo install -m 0644 test.php /var/www/html/apex-bench.php
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/apex-bench.php
wrk -t2 -c100 -d30s --latency http://127.0.0.1/apex-bench.php
```

For 1,000 local connections, use enough client threads:

```bash
wrk -t8 -c1000 -d30s --timeout 10s --latency \
  http://127.0.0.1/apex-bench.php
sudo rm /var/www/html/apex-bench.php
```

This setup completed 539,573 requests in 15 seconds with zero HTTP or socket
errors. Use a separate load-generator machine for production capacity tests.
Same-host `wrk` steals CPU from Apache.

## Troubleshooting

**Module fails to load / `apachectl -t` errors on `LoadFile`/`LoadModule`:**
Confirm both mod_apex packages are installed, then check that
`/usr/local/php-zts/lib/libphp.so` and the module file named in Apache's
message exist. Reinstall the matching package pair if either one is missing.

**Error log shows `mod_apex: requires a threaded MPM; skipping PHP engine
init in this process`:** Apache is still using its old request mode. Repeat
[Make Apache use mod_apex for PHP](#1-make-apache-use-mod_apex-for-php), then
run `sudo apachectl -M | grep mpm`.

**`.php` requests return 500, or the error log shows `mod_apex: expected PHP
handler mapping is 'php-script' or 'application/x-httpd-php'`:** the
`<FilesMatch \.php$>` block routing to `SetHandler php-script` is missing or
was overridden by another vhost/`.htaccess`. Add it again from
[Map PHP requests](#2-map-php-requests).

**Error log shows `mod_apex: php_embed_init() failed in child_init`:** PHP's
own startup failed (bad `php.ini` directive, an extension that failed to
load, etc.) -- Apache's error log is intentionally terse here since this
happens deep in PHP engine init. Run the ZTS CLI binary directly for a much
more detailed error:

```bash
/usr/local/php-zts/bin/php -v
/usr/local/php-zts/bin/php -m       # lists loaded extensions
/usr/local/php-zts/bin/php --ini    # shows which php.ini/scan dirs are used
```

**`opcache_get_status()` returns `false` / no OPcache speedup observed:**
first confirm you are testing through Apache, not the PHP command line. Use
the web check in [OPcache](#opcache): it should show
`sapi=apache2handler` and `opcache=on`.

**Fatal errors show a generic message instead of details, even locally:**
this is intentional (`ApexVerboseErrors` defaults to `Off` to avoid leaking
internal details in production). Temporarily set `ApexVerboseErrors On` in
the vhost/`<IfModule apex_module>` block, reproduce, then set it back to
`Off` before shipping -- never leave it `On` in production.

**Distro PHP (`mod_php`/`php-fpm`) still seems to be handling requests:**
repeat [Make Apache use mod_apex for PHP](#1-make-apache-use-mod_apex-for-php)
and verify with:

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
# expect: apex_module and mpm_event_module present, php_module absent
```

**Quick diagnostic commands:**

```bash
sudo apachectl -M                              # confirm loaded modules
curl -sS http://127.0.0.1/your-check.php       # confirm your PHP site responds
sudo tail -f /var/log/apache2/error.log         # watch startup/request errors live
```
