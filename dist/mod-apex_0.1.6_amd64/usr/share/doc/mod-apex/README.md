# mod_apex

**PHP that lives inside Apache -- not next to it.**

mod_apex is an Apache module that embeds a persistent, per-thread PHP (ZTS)
runtime directly into Apache's `event` MPM worker threads. No forked child
processes reloading PHP on every request, no FastCGI socket hop to a
separate PHP-FPM pool -- just your PHP app running in-process, in the same
thread that's already handling the HTTP request.

## Why mod_apex

- **No proxy hop.** Unlike PHP-FPM, there's no FastCGI socket round-trip to
  a separate worker pool -- PHP runs in the same Apache thread handling the
  request.
- **Modern, thread-safe, unlike `mod_php`.** Built with PHP's ZTS (Zend
  Thread Safety) mode, so it runs natively on Apache's threaded `event` MPM
  -- no forced fallback to single-threaded `prefork`, no one-process-per-
  connection memory cost.
- **OPcache + JIT that actually work.** Stock PHP's `embed` SAPI is
  hardcoded out of OPcache's SAPI allowlist. mod_apex presents itself as
  `apache2handler` to unlock full OPcache and JIT support -- something a
  naive PHP-embed integration does not get for free.
- **One less moving part.** No separate process manager to size, monitor,
  or restart independently of Apache.

Real benchmarking against PHP-FPM (same PHP build, extensions, and
OPcache/JIT settings; `wrk -t2 -c100`), on both a trivial script and a full
WordPress install:

| Workload | mod_apex | PHP-FPM | Result |
| --- | --- | --- | --- |
| Trivial script, throughput | 22,245 req/s | 22,185 req/s | Essentially tied |
| Trivial script, avg latency | 5.22 ms | 7.32 ms | mod_apex ~29% lower |
| WordPress, throughput | 185.4 req/s | 185.3 req/s | Essentially tied |
| WordPress, avg latency | 549.6 ms | 1.12 s | mod_apex ~2x lower |
| WordPress, latency stdev / max | 279.8 ms / 1.99 s | 1.78 s / 9.33 s | mod_apex far more consistent |

Throughput ties because both are ultimately bound by the same PHP execution
and OPcache; the win is in latency and consistency -- no proxy queueing, no
separate pool to saturate.

## Features

- Persistent per-thread PHP (ZTS/embed) runtime, no per-request process fork.
- OPcache + JIT enabled and working (packaged builds ship JIT on by default:
  `tracing` mode, 128M buffer).
- Full extension set for real-world apps: APCu, Redis, Imagick, mbstring,
  intl, zip, bcmath, soap, GD, sodium, gmp, curl, openssl, zlib, sqlite3,
  PDO (sqlite3/mysqli), exif, xsl -- covering WordPress, Drupal, and Symfony.
- Ships as a Docker image, Debian/Ubuntu `.deb` pair, or Fedora RPM pair --
  all built from one shared script, so the PHP build, OPcache/JIT settings,
  and extension list never drift between them.
- Production-conscious defaults: generic (non-leaking) fatal-error pages,
  with an opt-in `ApexVerboseErrors` for local debugging.
- Compiler/linker hardening applied automatically
  (`-D_FORTIFY_SOURCE=2 -fstack-protector-strong`, `-Wl,-z,relro -Wl,-z,now`).

## License

[PolyForm Internal Use License 1.0.0](https://polyformproject.org/licenses/internal-use/1.0.0) -- free to use and modify internally, redistribution not permitted -- see [LICENSE](LICENSE).

## Installation

### Option A: Docker

Self-contained Apache + PHP (ZTS/embed, OPcache+JIT) + mod_apex, built
entirely from source in a multi-stage build.

```sh
docker build -t mod-apex .
docker run --rm -p 8080:80 -v "$PWD/app:/var/www/html:ro" mod-apex
```

### Option B: Server install (prebuilt `mod_apex.so` + `build-php-zts.sh`)

Use this when you want to install straight onto a server without compiling
mod_apex yourself -- you still need a PHP ZTS runtime, built once via the
shared script, but mod_apex itself comes from an already-built `.so`/`.deb`.

**1. Build the PHP ZTS runtime** (requires root; installs to
`/usr/local/php-zts` by default):

```bash
sudo ./packaging/build-php-zts.sh
```

This compiles PHP (ZTS + embed + OPcache/JIT) and the APCu/Redis/Imagick
extensions, and installs them to `/usr/local/php-zts`.

**2. Install the prebuilt `mod_apex.so`:**

```bash
sudo dpkg -i dist/mod-apex_*.deb
sudo apt-get -f install   # pulls in apache2/libapr1 if missing
```

This drops in `/usr/lib/apache2/modules/mod_apex.so` and
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

**3. Route `.php` requests to mod_apex** (add to your vhost or
`conf-available`, see [docker/apex.conf](docker/apex.conf) for a full
example):

```apache
<FilesMatch \.php$>
    SetHandler php-script
</FilesMatch>
```

**4. Validate and restart:**

```bash
sudo apachectl -t
sudo systemctl restart apache2
curl -sS http://127.0.0.1/sapi_check.php   # expect: sapi=apache2handler
```

### Disabling the distro's preinstalled PHP

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

## Settings For Best Performance

**`opcache.ini`:**

- `opcache.validate_timestamps=0` -- skips a per-request file-staleness
  check. Restart/reload Apache (or call `opcache_reset()`) as part of your
  deploy process when using it.
- `opcache.jit=tracing` with `opcache.jit_buffer_size=128M` -- enabled by
  default in packaged builds; negligible fixed cost, helps numerically-heavy
  application code.

**Apache event MPM** (`/etc/apache2/mods-enabled/mpm_event.conf`), tuned for
100+ concurrent connections:

```apache
StartServers            4
ServerLimit             32
ThreadLimit             64
ThreadsPerChild         64
MinSpareThreads         128
MaxSpareThreads         2048
MaxRequestWorkers       2048
MaxConnectionsPerChild  0
```

Set `MaxSpareThreads` to `ServerLimit*ThreadsPerChild` so idle spare threads
can never exceed the max and Apache never scale-down-kills a child
mid-flight -- this avoids a known stock-Apache `mod_proxy` crash if you also
run a parallel proxied route.

**Keepalive** (`/etc/apache2/apache2.conf`):

```apache
KeepAlive Off
MaxKeepAliveRequests 10000
KeepAliveTimeout 5
```

**Linux host limits** (for very high connection counts):

```bash
ulimit -n 65535
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sudo sysctl -w net.ipv4.ip_local_port_range='1024 65000'
```

Once OPcache is active, remaining latency under high concurrency is genuine
CPU cost of executing application code -- further gains require reducing
per-request PHP work (page/object caching, fewer plugins) or more CPU
capacity, not additional tuning.
