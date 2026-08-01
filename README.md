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
entirely from source in a multi-stage build ([Dockerfile](Dockerfile)).
Works identically with Docker or Podman.

**Quick start:**

```sh
docker build -t mod-apex .
docker run --rm -p 8080:80 -v "$PWD/app:/var/www/html:ro" mod-apex
curl -sS http://127.0.0.1:8080/test.php
```

Mount your application's document root at `/var/www/html`; without a mount
the image only serves the built-in [test.php](test.php) smoke-test page.

**Podman:** no rootless-specific changes are needed --

```sh
podman build -t mod-apex .
podman run --rm -p 8080:80 -v "$PWD/app:/var/www/html:ro" mod-apex
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
(`apache2ctl -D FOREGROUND`), so `docker logs <container>` shows Apache/PHP
output directly. The same access/error logs also exist inside the container
under `/var/log/apache2/`:

```sh
docker logs -f <container>
docker exec <container> tail -f /var/log/apache2/error.log
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

On Fedora/RHEL-family systems, install the RPM pair instead (`php-zts-full`
must be installed first, since `mod_apex.rpm` depends on it):

```bash
sudo dnf install ./dist/rpmbuild/RPMS/x86_64/php-zts-full-*.rpm
sudo dnf install ./dist/rpmbuild/RPMS/x86_64/mod_apex-*.rpm
```

This installs PHP ZTS to `/usr/local/php-zts`, drops
`/usr/lib64/httpd/modules/mod_apex.so`, and enables it via
`/etc/httpd/conf.modules.d/10-mod_apex.conf` +
`/etc/httpd/conf.d/mod_apex.conf`. Both RPMs are produced by
`./tools/build_rpm.sh` (see [packaging/rpm](packaging/rpm) for the specs).

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
curl -sS http://127.0.0.1/test.php   # expect: sapi=apache2handler
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
[Disabling the distro's preinstalled PHP](#disabling-the-distros-preinstalled-php)
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

**Crashes or segfaults under load:** use
[tools/apache_crash_watch.sh](tools/apache_crash_watch.sh) to wrap a
benchmark and watch for crash signatures
(`AH00051`, `reslist_cleanup`, `Segmentation fault`, `exit signal Abort`,
`AH02537`) in the error log plus any new files under
`/var/lib/apache2/coredumps`:

```bash
TRUNCATE_LOG=1 ./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/test.php
```

One known cause: `MaxSpareThreads` not matching `ServerLimit*ThreadsPerChild`
(see [Settings For Best Performance](#settings-for-best-performance)) lets
Apache scale-down-kill a child mid-flight; if that child still holds pooled
`mod_proxy`/`mod_proxy_fcgi` backend connections, stock Apache's `mod_proxy`
can crash on the resulting reslist cleanup.

**Distro PHP (`mod_php`/`php-fpm`) still seems to be handling requests:**
re-run
[Disabling the distro's preinstalled PHP](#disabling-the-distros-preinstalled-php)
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

## Production Readiness

Two gate scripts in [tools/](tools) automate the checks worth running before
(and periodically after) a production rollout:

- **[tools/prod_readiness_gate.sh](tools/prod_readiness_gate.sh)** --
  guardrails (`apachectl -t`, service active, health endpoints for the
  mod_apex/FPM/app routes), then a soak-and-crash gate (a sustained `wrk`
  load run through `apache_crash_watch.sh`, failing if any new core dumps or
  crash-signature log lines appear), then throughput/latency threshold
  checks against configurable minimums (`APP_RPS_MIN`, `APP_READ_ERR_MAX`,
  etc.).
- **[tools/security_gate.sh](tools/security_gate.sh)** -- five categories:
  static analysis/hardening (`cppcheck` if available, banned libc calls like
  `strcpy`/`system`/`gets` in [mod_apex.c](mod_apex.c), compiler hardening
  flags present), fuzz/edge-input handling (oversized and special-character
  headers, conflicting `Content-Length`/`Transfer-Encoding` requests),
  dependency/update checks (pending `apache2`/`php`/`libapr`/`openssl`
  upgrades), the security/compat behavior suite
  ([tools/common_app_compat_smoke.sh](tools/common_app_compat_smoke.sh)),
  and least-privilege/service hardening (worker running as `www-data`,
  `mod_apex.so` not group/other-writable, systemd `LimitNOFILE` override
  present, threaded `mpm_event` active).

Run both against a staging environment that mirrors production before every
rollout; treat any `FAIL` as blocking and any `WARN` as worth reviewing
(e.g. a pending security update) even if not strictly blocking:

```bash
./tools/security_gate.sh
./tools/prod_readiness_gate.sh
```

**Production checklist** (defaults already applied by the packaged builds
unless noted):

- `ApexVerboseErrors Off` (default) -- generic fatal-error pages, no internal
  detail leaked to clients.
- `opcache.validate_timestamps=0` -- and `opcache_reset()` (or an Apache
  reload) wired into your deploy process, since file changes won't be
  picked up otherwise.
- MPM/keepalive tuned per
  [Settings For Best Performance](#settings-for-best-performance), with
  `MaxSpareThreads` correctly bounded.
- Distro `mod_php`/`php-fpm` (NTS) disabled -- see
  [Disabling the distro's preinstalled PHP](#disabling-the-distros-preinstalled-php).
- Apache worker processes running as an unprivileged user (`www-data`), not
  `root`.
- `mod_apex.so` not writable by group/other (`644`/`640`/`444`).
- A systemd override raising `LimitNOFILE` for the Apache service under high
  concurrency.
- Compiler/linker hardening flags in place (`-D_FORTIFY_SOURCE=2
  -fstack-protector-strong`, `-Wl,-z,relro -Wl,-z,now`) -- already applied
  automatically by [build-install.sh](build-install.sh); verify with
  `apxs -q CFLAGS` or `security_gate.sh`'s static-analysis check.
- No pending security-relevant package updates
  (`apache2`/`php`/`libapr`/`openssl`) on the host.
