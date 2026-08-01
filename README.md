# mod_apex

mod_apex is an Apache module that embeds PHP (ZTS) with a persistent per-thread runtime.

## License

Apache License 2.0 -- see [LICENSE](LICENSE).

## Requirements

1. Apache 2.4 with `mpm_event` enabled.
2. PHP 8.4+ (8.5+ compatible target) built with:

```bash
./configure --enable-embed --enable-maintainer-zts ...
make
sudo make install
```

1. Build tools and headers (`apxs`, APR, APR-util, compiler toolchain).

## Compile And Install

Recommended (helper script):

```bash
# Build only (default for non-root users)
./build-install.sh

# Force install + module enable (requires root)
sudo INSTALL_MODE=always ./build-install.sh
```

Script usage:

```bash
./build-install.sh --help
```

Environment controls:

- `PHP_PREFIX`: PHP ZTS prefix (default `/usr/local/php-zts`)
- `PHP_CONFIG`: path/name for php-config (default `$PHP_PREFIX/bin/php-config`)
- `APXS`: apxs command (default `apxs`)
- `INSTALL_MODE`: `auto` (default), `always`, or `never`

Manual fallback compile/install:

```bash
PHP_PREFIX=/usr/local/php-zts
PHP_CONFIG="$PHP_PREFIX/bin/php-config"
PHP_INC="$($PHP_CONFIG --includes) -I$($PHP_CONFIG --include-dir)/sapi/embed"

apxs -c -i -a \
 -Wc,"$PHP_INC" \
 -Wl,"-L$PHP_PREFIX/lib -lphp" \
 mod_apex.c
```

## Quick Validation

```bash
sudo apachectl -t
sudo systemctl restart apache2
curl -sS http://127.0.0.1/sapi_check.php
curl -sS http://127.0.0.1/test.php
```

`test.php` is a smoke endpoint for benchmark stability and quick routing checks.

Expected `sapi_check.php` output:

```text
sapi=apache2handler
```

Note: mod_apex reports the SAPI name as `apache2handler` (not the stock `embed` name) so that OPcache's SAPI allowlist accepts it -- see [OPcache Support](#opcache-support) below. This is cosmetic/identification only; the actual request lifecycle is still the embed SAPI's `php_request_startup()`/`php_request_shutdown()` model.

## OPcache Support

PHP's OPcache accelerator refuses to activate on SAPIs that aren't on its internal allowlist (`ext/opcache/ZendAccelerator.c`, `accel_find_sapi()`): `apache`, `apache2handler`, `fastcgi`, `cgi-fcgi`, `fpm-fcgi`, `litespeed`, `uwsgi`, `frankenphp`, `ngx-php`, `cli-server`, plus `cli`/`phpdbg` with `opcache.enable_cli`. The stock embed SAPI name (`"embed"`) is not on that list, so `opcache_get_status()` silently returns `false` and every request fully re-lexes/parses/compiles the entire script + its includes from scratch -- verified to be independent of mod_apex's own request lifecycle or threading (reproduced with a standalone single-thread and multi-pthread `php_embed_init()` harness with no Apache involved at all).

Since mod_apex already runs a single `php_embed_init()`/`php_module_startup()` at child-init time followed by many per-request `php_request_startup()`/`php_request_shutdown()` cycles (the same "one MINIT, many RINIT" model the allowlisted SAPIs use), it is safe to report a matching SAPI name. `apex_post_config()` sets:

```c
php_embed_module.name        = "apache2handler";
php_embed_module.pretty_name = "mod_apex (embedded PHP via Apache, OPcache-compatible SAPI name)";
```

before Apache forks child processes, so every child inherits it. This is what unlocks OPcache -- no other configuration is required beyond the normal `zend_extension=opcache.so` + `opcache.enable=1` ini settings.

Side effect: `php_sapi_name()` now reports `"apache2handler"` instead of `"embed"` inside PHP scripts running under mod_apex. This is purely a string identity change (no behavior depends on it in this codebase); if application code branches on `php_sapi_name() === 'embed'` specifically, update it to check for `'apache2handler'` (or check for a mod_apex-specific marker instead).

### Recommended opcache.ini tuning

- `opcache.validate_timestamps=0` -- skips a per-request `fstat()` staleness check on every included file. Doesn't move throughput much on its own, but noticeably reduces socket timeouts/read errors under concurrent load in testing. Since this disables automatic pickup of edited PHP files, restart/reload Apache (or `opcache_reset()`) as part of your deploy process when using it.
- Once OPcache is active, remaining latency under high concurrency is genuine CPU cost of executing application code (confirmed via `top`/`vmstat` showing full CPU saturation, not database or lock contention) -- further gains require reducing per-request PHP work (page/object caching, fewer plugins) or more CPU capacity, not additional php.ini tuning.

## Security Hardening

### Compiler/linker hardening

`build-install.sh` compiles and links with hardening flags applied automatically:

- Compile: `-D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security`
- Link: `-Wl,-z,relro -Wl,-z,now`

No configuration is required; these are always passed via `APXS_ARGS`.

### `ApexVerboseErrors` directive

Controls whether mod_apex's fatal-error response page includes internal diagnostic detail (for example PHP/plugin/extension incompatibility hints) or a generic message.

```apache
<IfModule apex_module>
    # Off (default): generic error body, no internal detail leaked to clients.
    # On: verbose diagnostic body, useful in development/staging only.
    ApexVerboseErrors Off
</IfModule>
```

- Default: `Off`.
- Scope: `RSRC_CONF` (server/vhost config, inherited unless explicitly overridden per-vhost).
- Keep `Off` in production to avoid leaking internal details to clients.

### Trusted proxy / forwarded headers

mod_apex exposes every incoming request header to PHP as `$_SERVER['HTTP_*']`, the same as mod_php/PHP-FPM/CGI. This means `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For`, and `X-Real-IP` are only as trustworthy as any other client-supplied header — mod_apex does not (and should not) filter or gate them itself.

If this Apache sits behind a reverse proxy/load balancer:

- Use Apache's `mod_remoteip` (not mod_apex) to correctly resolve `REMOTE_ADDR` from a trusted proxy:

  ```apache
  LoadModule remoteip_module modules/mod_remoteip.so
  RemoteIPHeader X-Forwarded-For
  RemoteIPTrustedProxy 127.0.0.1
  ```

- Validate/strip forwarded headers at the proxy/load balancer, or at the application/framework layer (Symfony trusted proxies, Laravel `TrustProxies`), rather than trusting them implicitly in PHP.

See [httpd.conf](httpd.conf) for a ready-to-use example.

## Troubleshooting

### 1) `php-config` not found

Symptom:

```text
error: php-config not found
```

Fix:

```bash
PHP_PREFIX=/usr/local/php-zts ./build-install.sh
# or
PHP_CONFIG=/path/to/php-config ./build-install.sh
```

### 2) Linker errors for `-lphp` or missing embed symbols

Symptom:

```text
cannot find -lphp
```

Fix:

1. Confirm your PHP build includes `--enable-embed --enable-maintainer-zts`.
2. Confirm `libphp` exists under your PHP prefix, for example `/usr/local/php-zts/lib`.
3. Rebuild/install using the helper script so include and link flags are applied consistently.

### 3) Apache starts but PHP source is served instead of executed

Symptom:

`.php` files return raw source code in HTTP response.

Fix:

1. Ensure `apex` module is loaded.
2. Ensure `.php` is mapped to `php-script` or `application/x-httpd-php`.
3. Restart Apache and check `sapi_check.php` returns `sapi=apache2handler`.

This module now fails fast on bad mapping: mis-mapped `.php` requests return `500` and log an explicit mapping error.

### 4) Wrong MPM mode

Symptom:

Apache logs include messages indicating threaded MPM is required.

Fix:

```bash
sudo a2dismod mpm_prefork php8.4 || true
sudo a2enmod mpm_event apex
sudo systemctl restart apache2
```

### 5) Verify active runtime quickly

```bash
sudo apachectl -M | grep -E 'apex_module|mpm_event_module|php_module'
curl -sS http://127.0.0.1/sapi_check.php
```

Expected:

1. `apex_module` and `mpm_event_module` are present.
2. `php_module` is absent for embed runtime.
3. `sapi_check.php` outputs `sapi=embed`.

High-Load Apache Tuning (100+ Connections)

When running `wrk` with `-c100` or higher, tune the live Apache config under `/etc/apache2` (not only the project-local `httpd.conf`).

1) Event MPM tuning (`/etc/apache2/mods-enabled/mpm_event.conf`)

```
StartServers            4
ServerLimit             32
ThreadLimit             64
ThreadsPerChild         64
MinSpareThreads         128
MaxSpareThreads         2048
MaxRequestWorkers       2048
MaxConnectionsPerChild  0
```

`MaxSpareThreads` is set to `ServerLimit*ThreadsPerChild` (the max possible
thread count) so idle spare threads can never exceed it and Apache never
scale-down-kills a child process. This matters if you also run a parallel
mod_proxy/mod_proxy_fcgi route (see "Enable FPM Path in Apache" below): a
child killed while still holding pooled backend connections has been
observed to crash stock Apache's `mod_proxy` (`ap_proxy_acquire_connection`
reslist-cleanup NULL deref), unrelated to mod_apex.

1) Keepalive tuning (`/etc/apache2/apache2.conf`)

Locked low-error mode (current default on this host):

```
KeepAlive Off
MaxKeepAliveRequests 10000
KeepAliveTimeout 5
```

Optional high-throughput mode (higher requests/sec, but higher read socket errors under extreme persistent-connection tests):

```
KeepAlive On
MaxKeepAliveRequests 10000
KeepAliveTimeout 1
```

Quick Copy/Paste for project-local [httpd.conf](httpd.conf)

```apache
<IfModule mpm_event_module>
 StartServers 4
 ServerLimit 32
 ThreadLimit 64
 ThreadsPerChild 64
 MinSpareThreads 128
 MaxSpareThreads 2048
 MaxRequestWorkers 2048
 MaxConnectionsPerChild 0
</IfModule>

KeepAlive Off
MaxKeepAliveRequests 10000
KeepAliveTimeout 5
```

On Debian/Ubuntu, Apache service mode reads `/etc/apache2/*` as the live runtime config.

Helper script for the live Apache profile:

```bash
sudo ./tools/apache_10k_tune.sh
```

One-command mode switch (throughput vs low-error):

```bash
./tools/apache_mode.sh status
./tools/apache_mode.sh throughput
./tools/apache_mode.sh low-error
```

`throughput` favors maximum RPS and may increase read socket errors at extreme concurrency.
`low-error` reduces socket-error frequency and crash risk signals at the cost of throughput.

Web asset performance profile (cache + compression):

```bash
./tools/apache_asset_perf.sh status
sudo ./tools/apache_asset_perf.sh apply
```

This profile improves frontend load speed for common PHP apps by:

- enabling cache headers for static assets (`css`, `js`, images, fonts)
- enabling Brotli/Deflate compression for text assets
- keeping dynamic responses (`php`, `html`, JSON) uncached

To disable and return to previous behavior:

```bash
sudo ./tools/apache_asset_perf.sh remove
```

`apache_10k_tune.sh` backs up the live Apache files once, applies the 10,000-connection values, validates syntax, and restarts Apache.

Helper script for the Linux-side limits:

```bash
sudo ./tools/os_10k_tune.sh
```

The script backs up the relevant host config, applies the file-descriptor and kernel queue limits, writes a systemd override for Apache, and restarts Apache.

1) Linux OS-side limits for 10,000 connections

Apache settings alone are not enough at this scale. Raise process, socket, and file-descriptor limits on the host too.

Example system-wide tuning:

```bash
# File descriptor limit for the Apache service user
ulimit -n 65535

# Kernel/network backlog and queueing
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sudo sysctl -w net.ipv4.ip_local_port_range='1024 65000'
```

Persist these in host config as needed:

```ini
# /etc/security/limits.conf
www-data soft nofile 65535
www-data hard nofile 65535
```

```ini
# /etc/systemd/system/apache2.service.d/override.conf
[Service]
LimitNOFILE=65535
```

If you apply the systemd override, reload and restart Apache:

```bash
sudo systemctl daemon-reload
sudo systemctl restart apache2
```

1) Validate and reload

```bash
sudo apachectl -t
sudo systemctl restart apache2
systemctl is-active apache2
```

1) Benchmark check (clean mode)

```bash
wrk -t2 -c1000 -d15s http://127.0.0.1/test.php
wrk -t2 -c1000 -d15s http://127.0.0.1/fpm/test.php
```

Crash-regression gate for benchmark runs:

```bash
./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/test.php
./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/fpm/test.php
```

Optional: truncate Apache error log before each gate run:

```bash
TRUNCATE_LOG=1 ./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/test.php
```

Production readiness gate (covers guardrails, soak, SLO sample, canary stages, and restart drill):

```bash
SOAK_SECONDS=60 SHORT_SECONDS=10 ./tools/prod_readiness_gate.sh
```

For a stricter run, increase soak duration and thresholds via environment variables:

```bash
SOAK_SECONDS=1800 SHORT_SECONDS=30 APP_RPS_MIN=12000 APP_READ_ERR_MAX=5000 ./tools/prod_readiness_gate.sh
```

Key gate variables:

- `BASE_URL` (default `http://127.0.0.1`)
- `APP_PATH` (default `/wordpress`)
- `APEX_PATH` (default `/test.php`)
- `FPM_PATH` (default `/fpm/test.php`)
- `SOAK_SECONDS`, `SHORT_SECONDS`
- `APP_RPS_MIN`, `APP_READ_ERR_MAX`
- `CANARY_RPS_MIN`, `CANARY_READ_ERR_MAX`

Security gate (covers static analysis/hardening, edge-input checks, dependency/update checks, app/security behavior tests, and least-privilege/service hardening):

```bash
./tools/security_gate.sh
```

Optional: skip package update checks if your environment blocks apt metadata refresh/listing:

```bash
INCLUDE_UPDATE_CHECKS=0 ./tools/security_gate.sh
```

One-command remediation + recheck (installs missing tools, applies safe package update, reruns security gate):

```bash
./tools/security_remediate_and_recheck.sh
```

Expected in locked low-error mode:

1. Lower read socket errors than keepalive-on mode.
2. Lower throughput than keepalive-on mode.
3. Under extreme local stress (`-t2 -c1000 -d15s`), small non-zero read errors can still appear.

Enable FPM Path in Apache

If you want a parallel PHP-FPM path while keeping default `.php` handling on `mod_apex`, configure `/fpm/...` as follows.

1) Ensure Apache modules and FPM service are enabled

```bash
sudo a2enmod proxy proxy_fcgi
sudo systemctl enable --now php8.4-fpm
```

1) Create the Apache FPM route config

```bash
sudo tee /etc/apache2/conf-available/apex-parallel-fpm.conf >/dev/null <<'EOF'
Alias /fpm/ /var/www/html/

<Directory /var/www/html>
 Require all granted
</Directory>

# Keep FastCGI backend timeout explicit under load.
ProxyTimeout 60

# Route only /fpm/*.php to php-fpm.
ProxyPassMatch "^/fpm/(.*\.php(/.*)?)$" "unix:/run/php/php8.4-fpm.sock|fcgi://localhost/var/www/html/$1"
EOF
```

> **Known issue:** combining this proxy route with an MPM config where
> `MaxSpareThreads` is well below `ServerLimit*ThreadsPerChild` can trigger a
> segfault in stock Apache's `mod_proxy` (`ap_proxy_acquire_connection`,
> `apr_reslist.c` assertion) when an idle child holding pooled FastCGI
> connections gets scale-down-killed under load. This is an Apache/APR bug,
> not mod_apex or php-fpm. Fix: set `MaxSpareThreads` to
> `ServerLimit*ThreadsPerChild` as shown above so idle children are never
> recycled mid-flight.

1) Enable config and reload Apache

```bash
sudo a2enconf apex-parallel-fpm
sudo apachectl -t
sudo systemctl restart apache2
```

1) Validate route and modules

```bash
sudo apachectl -M | egrep 'proxy_module|proxy_fcgi_module|apex_module'
curl -i http://127.0.0.1/fpm/test.php
```

Expected: `/fpm/test.php` returns HTTP 200 and is handled by FPM while `/test.php` stays on `mod_apex`.

Parallel runtime benchmark (mod_apex vs php-fpm)

Use the helper script to compare throughput and latency between the default `mod_apex` route and the parallel `/fpm/` route:

```bash
./tools/apex_fpm_bench.sh
```

Optional tuning via environment variables:

```bash
THREADS=2 CONNECTIONS=200 DURATION=15s BASE_URL=http://127.0.0.1 ./tools/apex_fpm_bench.sh
```

Defaults:

- `APEX_PATH=/test.php`
- `FPM_PATH=/fpm/test.php`

The script writes raw `wrk` outputs to:

- `./apex_wrk_last.txt`
- `./fpm_wrk_last.txt`

Expected outcome after tuning:

- Lower or no `Socket errors: read ...` on the PHP endpoint.
- Substantially reduced read socket errors on static endpoint benchmark runs.

Notes

- `mod_apex` includes a threaded-MPM safety guard; keep Apache on `mpm_event` for production.
- If read errors remain under extreme local benchmarks, investigate OS networking limits and local client-side test environment next.

Common PHP App Compatibility Probe

Use [probes/common-app-probe.php](probes/common-app-probe.php) to verify framework-critical `$_SERVER` behavior.

```bash
sudo cp probes/common-app-probe.php /var/www/html/common-app-probe.php

# Basic auth mapping check
curl -sS -u appuser:apppass 'http://127.0.0.1/common-app-probe.php?route=login'

# Proxy and front-controller path check
curl -sS \
 -H 'X-Forwarded-Proto: https' \
 -H 'X-Forwarded-Host: app.example.com' \
 -H 'X-Forwarded-For: 203.0.113.5' \
 'http://127.0.0.1/common-app-probe.php/index.php/admin/users?x=1'
```

Automated compatibility smoke (pass/fail)

```bash
./tools/common_app_compat_smoke.sh
```

Optional with performance sanity check:

```bash
RUN_WRK=1 ./tools/common_app_compat_smoke.sh
```

Bundle mod_apex For Debian/Ubuntu Download

Use the package builder to produce a distributable `.deb` artifact:

```bash
cd /home/bode/sites/mod_apex
chmod +x tools/build_deb.sh
VERSION=0.1.2 ./tools/build_deb.sh
```

If your PHP embed install is not under `/usr/local/php-zts`, point the builder at the correct PHP config:

```bash
PHP_CONFIG=/path/to/php-config VERSION=0.1.2 ./tools/build_deb.sh
# or
PHP_PREFIX=/custom/php-zts VERSION=0.1.2 ./tools/build_deb.sh
```

Output:

- `dist/mod-apex_<version>_<arch>.deb`

Install on Debian/Ubuntu:

```bash
sudo dpkg -i dist/mod-apex_0.1.2_$(dpkg --print-architecture).deb
sudo apt-get -f install
sudo apachectl -t
sudo systemctl restart apache2
```

Notes:

- The package installs `mod_apex.so` and `/etc/apache2/mods-available/apex.load`.
- `apex.load` is generated at package-build time from your selected `php-config`.
- The builder fails fast if `php-config --configure-options` does not include PHP embed and ZTS (`--enable-embed` and `--enable-zts` or `--enable-maintainer-zts`).
- Target systems must provide compatible PHP ZTS embed library at the same path detected during package build.
