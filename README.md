# mod_apex

**Run PHP inside Apache. Skip FastCGI. Keep the event MPM.**

mod_apex embeds a persistent PHP ZTS runtime in each Apache worker thread.
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

## Why mod_apex

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

- Persistent per-thread PHP (ZTS/embed) runtime, no per-request process fork.
- OPcache + JIT enabled and working (packaged builds ship JIT on by default:
  `tracing` mode, 128M buffer).
- Broad bundled extension set: APCu, Redis, Imagick, mbstring,
  intl, zip, bcmath, soap, GD, sodium, gmp, curl, openssl, zlib, sqlite3,
  PDO (sqlite3/mysqli), exif, and xsl. Verify every application's third-party
  extensions are ZTS-safe before deployment.
- Ships as a Docker image, Debian/Ubuntu `.deb` pair, or Fedora RPM pair.
  The PHP build paths share the same runtime builder and INI files.
- Production-conscious defaults: generic (non-leaking) fatal-error pages,
  with an opt-in `ApexVerboseErrors` for local debugging.
- Compiler/linker hardening applied automatically
  (`-D_FORTIFY_SOURCE=2 -fstack-protector-strong`, `-Wl,-z,relro -Wl,-z,now`).

## Requirements

- Apache 2.4 with the threaded `event` MPM.
- PHP 8.4+ built with `--enable-embed` and either `--enable-zts` or the
  legacy `--enable-maintainer-zts` spelling.
- Thread-safe PHP extensions.
- OPcache for production performance.

## License

[PolyForm Internal Use License 1.0.0](https://polyformproject.org/licenses/internal-use/1.0.0)
-- free to use and modify internally, redistribution not permitted -- see
[LICENSE](LICENSE).

## Installation

Pick one path:

- **Docker/Podman:** fastest test. No host Apache changes.
- **Debian/Ubuntu or Fedora packages:** easiest server install.
- **Source build:** best for mod_apex development.

Every server path uses the same order: install PHP ZTS, disable conflicting
mod_php, enable `mpm_event`, install mod_apex, map `.php`, validate, restart.

### Option A: Docker

Self-contained Apache + PHP (ZTS/embed, OPcache+JIT) + mod_apex, built
entirely from source in a multi-stage build ([Dockerfile](Dockerfile)).
The same image works with Docker or Podman. Rootless user IDs, SELinux bind
mount labels, and host networking can still differ between the two engines.

**Quick start:**

```sh
docker build -t mod-apex .
docker run --rm -d --name mod-apex-demo -p 8080:80 mod-apex
curl -sS http://127.0.0.1:8080/test.php
docker stop mod-apex-demo
```

The first run uses the built-in [test.php](test.php). After it passes, mount
an existing application directory at `/var/www/html`:

```bash
docker run --rm -p 8080:80 -v "$PWD/app:/var/www/html:ro" mod-apex
```

The host `app/` directory must exist. A bind mount replaces the image's
built-in document root, including its smoke page.

**Podman:** no rootless-specific changes are needed --

```sh
podman build -t mod-apex .
podman run --rm -d --name mod-apex-demo -p 8080:80 mod-apex
curl -sS http://127.0.0.1:8080/test.php
podman stop mod-apex-demo
```

The image still runs Apache as root internally (worker processes drop
privileges to `www-data`, same as a normal package install), which
`podman run` maps the same way `docker run` does.

**Customizing the PHP build:** PHP/extension versions are `ARG`s at the top
of the [Dockerfile](Dockerfile), overridable at build time:

```sh
docker build \
  --build-arg PHP_VERSION=8.4.21 \
  --build-arg APCU_VERSION=5.1.24 \
  --build-arg REDIS_VERSION=6.1.0 \
  --build-arg IMAGICK_VERSION=3.8.1 \
  -t mod-apex .
```

**Apache/PHP config baked into the image:** [docker/](docker) holds the
exact files `COPY`'d in --
[docker/apex.conf](docker/apex.conf) (mod_apex + `ApexVerboseErrors`),
[docker/mpm_event.conf](docker/mpm_event.conf) (event MPM tuning),
[docker/keepalive-tuning.conf](docker/keepalive-tuning.conf),
[docker/servername.conf](docker/servername.conf),
[docker/security-hardening.conf](docker/security-hardening.conf), and
[docker/000-mod-apex.conf](docker/000-mod-apex.conf) (the default vhost).
`php.ini`/OPcache/APCu/Redis/Imagick settings come from
[packaging/php-ini](packaging/php-ini), installed to
`/usr/local/php-zts/etc/conf.d/` during the build. Changing any of these
requires editing the file and rebuilding the image, or overriding one at
`docker run` time with a bind mount, e.g.
`-v "$PWD/packaging/php-ini/opcache.ini:/usr/local/php-zts/etc/conf.d/10-opcache.ini:ro"`.

**Logs:** the container's `CMD` runs Apache in the foreground
(`apache2ctl -D FOREGROUND`). Request access and error logs are files inside
the container under `/var/log/apache2/`; `docker logs` mainly shows Apache's
foreground process output:

```sh
docker exec <container> tail -f /var/log/apache2/error.log
docker exec <container> tail -f /var/log/apache2/access.log
```

### Option B: Server packages

Use packages when you want a repeatable server install without compiling
mod_apex on the target host.

On an existing Apache server, read [Server setup](#server-setup) before
enabling mod_apex. Install PHP ZTS first, then disable conflicting handlers,
enable `mpm_event`, and install/enable mod_apex.

**Debian or Ubuntu:** install the PHP ZTS package first, then mod_apex:

```bash
sudo dpkg -i dist/php-zts-full_*.deb
sudo apt-get -f install
sudo a2dismod php8.4 || true
sudo a2disconf php8.4-fpm || true
sudo a2dismod mpm_prefork || true
sudo a2enmod mpm_event
sudo dpkg -i dist/mod-apex_*.deb
```

Match `php8.4` to the distro PHP version. The package enables mod_apex, so
disable conflicting handlers before installing it.

Building PHP requires these Debian/Ubuntu dependencies:

```bash
sudo apt-get update
sudo apt-get install -y build-essential autoconf automake libtool pkg-config \
  curl ca-certificates apache2-dev libxml2-dev libssl-dev \
  libcurl4-openssl-dev zlib1g-dev libsqlite3-dev libonig-dev libicu-dev \
  libzip-dev libxslt1-dev libfreetype6-dev libjpeg62-turbo-dev \
  libwebp-dev libpng-dev libsodium-dev libgmp-dev libmagickwand-dev dpkg-dev
```

To create both packages from a clone, build inside the exact target distro
and release; PHP's linked library versions differ between releases:

```bash
sudo ./tools/build_php_zts_deb.sh
sudo ./tools/build_deb.sh
```

To install the runtime directly instead of creating its package:

```bash
sudo ./packaging/build-php-zts.sh
```

The PHP build scripts download and compile PHP and its extensions. They do
not install operating-system build dependencies for you.

The mod_apex package installs `/usr/lib/apache2/modules/mod_apex.so`, creates
`/etc/apache2/mods-available/apex.load`, and enables the module.

Alternatively, copy the `.so` and load file manually if you're not on a
`.deb`-based system:

```bash
sudo cp mod_apex.so /usr/lib/apache2/modules/mod_apex.so
sudo tee /etc/apache2/mods-available/apex.load >/dev/null <<'EOF'
LoadFile /usr/local/php-zts/lib/libphp.so
LoadModule apex_module /usr/lib/apache2/modules/mod_apex.so
EOF
sudo a2enmod apex
```

**Fedora:** install the RPM pair in this order. Use the architecture directory
that the build produced (`x86_64` is only an example):

```bash
sudo dnf install ./dist/rpmbuild/RPMS/x86_64/php-zts-full-*.rpm
sudo dnf install ./dist/rpmbuild/RPMS/x86_64/mod_apex-*.rpm
```

This installs PHP ZTS to `/usr/local/php-zts`, drops
`/usr/lib64/httpd/modules/mod_apex.so`, and enables it via
`/etc/httpd/conf.modules.d/10-mod_apex.conf` +
`/etc/httpd/conf.d/mod_apex.conf`.

Build the PHP RPM on Fedora, install it so `rpmbuild` can satisfy mod_apex's
build requirement, then build mod_apex:

```bash
./tools/build_rpm.sh php-zts-full
sudo dnf install ./dist/rpmbuild/RPMS/*/php-zts-full-*.rpm
./tools/build_rpm.sh mod_apex
```

See [packaging/rpm](packaging/rpm) for the specs. RHEL may require additional
repositories and different development-package availability; it is not a
documented build target yet.

Fedora uses `httpd` instead of Debian's `apache2`: validate with
`sudo httpd -t`, restart with `sudo systemctl restart httpd`, and inspect
modules with `sudo httpd -M`.

### Option C: Build mod_apex from source

First install PHP ZTS under `/usr/local/php-zts`. The dependency list in
Option B is the Debian/Ubuntu starting point; package names differ on other
distributions. Then build mod_apex without changing the server:

```bash
INSTALL_MODE=never ./build-install.sh
```

Expected artifact: `.libs/mod_apex.so`. Install it after the build passes:

```bash
sudo INSTALL_MODE=always ./build-install.sh
```

Custom PHP prefix:

```bash
sudo PHP_PREFIX=/opt/php-zts \
  PHP_CONFIG=/opt/php-zts/bin/php-config \
  INSTALL_MODE=always ./build-install.sh
```

Manual fallback:

```bash
apxs -c -i -a mod_apex.c -lphp \
  -L/usr/local/php-zts/lib \
  -I/usr/local/php-zts/include/php
```

Whichever source path you use, Apache must load the nonstandard PHP library
before the module. Confirm the enabled module file contains this order:

```apache
LoadFile /usr/local/php-zts/lib/libphp.so
LoadModule apex_module /usr/lib/apache2/modules/mod_apex.so
```

The automated install adds `LoadFile` to an existing Debian-style
`/etc/apache2/mods-available/apex.load`. On another layout, add both lines to
the server's module configuration yourself before running `apachectl -t`.

## Server setup

### 1. Disable conflicting PHP handlers

Most distros ship PHP built **NTS (Non Thread Safe)** -- fine for
single-threaded `prefork`/CGI/FPM use, but unsafe to load into Apache's
threaded `event` MPM, which is why mod_apex requires its own separate
**ZTS (Zend Thread Safe)** build instead. The distro's NTS build shows up in
two places that both need to be disabled so they don't fight mod_apex for
the `.php` handler or keep Apache pinned to `prefork`:

```bash
# Disable mod_php (NTS, tied to prefork) and force the threaded event MPM
# mod_apex requires
sudo a2dismod php8.4 || true          # match your installed PHP version
sudo a2disconf php8.4-fpm || true     # remove Apache's FPM handler mapping
sudo a2dismod mpm_prefork || true
sudo a2enmod mpm_event

# If a distro php-fpm service (also NTS) is running and not otherwise in
# use, stop it
sudo systemctl disable --now php8.4-fpm || true

sudo apachectl -t
sudo systemctl restart apache2
```

Verify only mod_apex is serving PHP afterward:

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
# expect: apex_module and mpm_event_module present, php_module absent
```

The distro's NTS **`php` CLI binary** itself is unaffected by the above --
it stays installed (used by cron jobs, composer, CLI scripts, etc.) and
that's fine, since it never loads into Apache. If you need to make the ZTS
build your default `php` on the CLI too (or just want to avoid ambiguity
about which `php` a script picks up):

```bash
sudo update-alternatives --config php
# or bypass alternatives entirely and call the ZTS binary directly:
/usr/local/php-zts/bin/php -v
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
Fedora, substitute `httpd` for `apache2`/`apachectl` as described in
Option B. Adjust `/var/www/html` if your vhost uses another document root.

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
Confirm `LoadFile /usr/local/php-zts/lib/libphp.so` points at the actual
install prefix (`PREFIX` at build time, `/usr/local/php-zts` by default) and
that the file exists -- a mismatched prefix (e.g. built with a custom
`PREFIX` but the config still points at the default) is the most common
cause.

**Error log shows `mod_apex: requires a threaded MPM; skipping PHP engine
init in this process`:** `mpm_prefork` is still active instead of
`mpm_event`. Run through
[Server setup](#server-setup)
again and confirm with `sudo apachectl -M | grep mpm`.

**`.php` requests return 500, or the error log shows `mod_apex: expected PHP
handler mapping is 'php-script' or 'application/x-httpd-php'`:** the
`<FilesMatch \.php$>` block routing to `SetHandler php-script` is missing or
was overridden by another vhost/`.htaccess`. See [httpd.conf](httpd.conf) or
[docker/apex.conf](docker/apex.conf) for the expected block.

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
means PHP is running under the stock `"embed"` SAPI name instead of the
`"apache2handler"` override `apex_post_config` sets -- see the "Known
Pitfalls" entry in [AGENTS.md](AGENTS.md) for the full explanation. Confirm
with `php_sapi_name()` in a request (see [test.php](test.php)) -- it should print
`apache2handler`, not `embed`.

**Fatal errors show a generic message instead of details, even locally:**
this is intentional (`ApexVerboseErrors` defaults to `Off` to avoid leaking
internal details in production). Temporarily set `ApexVerboseErrors On` in
the vhost/`<IfModule apex_module>` block, reproduce, then set it back to
`Off` before shipping -- never leave it `On` in production.

**Distro PHP (`mod_php`/`php-fpm`) still seems to be handling requests:**
re-run
[Server setup](#server-setup)
and verify with:

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
# expect: apex_module and mpm_event_module present, php_module absent
```

**Quick diagnostic commands:**

```bash
sudo apachectl -M                              # confirm loaded modules
curl -sS http://127.0.0.1/test.php             # confirm SAPI + basic response
sudo tail -f /var/log/apache2/error.log         # watch startup/request errors live
```
