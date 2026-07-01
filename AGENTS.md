# AGENTS.md

Instructions for AI coding agents working in this repository.

## Scope
- Project: Apache module `mod_apex` embedding PHP (ZTS) with persistent per-thread runtime.
- Primary implementation: [mod_apex.c](mod_apex.c)
- Operational setup: [README.md](README.md), [build-install.sh](build-install.sh), [httpd.conf](httpd.conf)

## Working Style
- Act as a production C engineer: prefer correctness, ABI compatibility, and explicit error handling over cleverness.
- Research before deciding: read existing code and docs first, then change only what is necessary.
- Do not delete or rewrite previously working behavior unless explicitly requested.
- Preserve public behavior and Apache/PHP integration points unless the task requires a change.
- Keep patches small and reviewable.

## Build And Install
- Primary build/install flow:
  - `./build-install.sh`
- Manual fallback (from README):
  - `apxs -c -i -a mod_apex.c -lphp -L/usr/local/lib -I/usr/local/include/php`
- Requirements summary:
  - Apache 2.4 with event MPM
  - PHP 8.4+ built with `--enable-embed --enable-maintainer-zts`

## Validation
- Syntax and module load checks should happen before runtime tests.
- Runtime smoke test endpoint: [test.php](test.php)
- Example benchmark command (from README):
  - `wrk -t2 -c100 -d10s http://localhost/test.php`

## Architecture Notes
- Request handling entry point: `apex_handler` in [mod_apex.c](mod_apex.c)
- PHP engine bootstrap: `apex_post_config` in [mod_apex.c](mod_apex.c)
- `apex_post_config` sets `php_embed_module.name = "apache2handler"` (before Apache forks children) so OPcache's SAPI allowlist accepts it; see [README.md](README.md#opcache-support). Do not revert this to the stock `"embed"` name -- doing so silently disables OPcache again (`opcache_get_status()` returns `false`, full recompilation on every request).
- Per-request lifecycle:
  1. `php_request_startup()`
  2. Populate `SG(request_info)` and request context
  3. `php_execute_script(...)`
  4. `php_request_shutdown()`
- SAPI callbacks wired in post-config:
  - `ub_write`, `flush`, `read_post`, `header_handler`

## Safety Rules For Edits
- Keep `php_request_startup()` and `php_request_shutdown()` balanced per request.
- Avoid touching request context after shutdown.
- Preserve thread-local assumptions (`SG(server_context)`, ZTS model).
- Keep Apache handler guard checks intact unless asked to broaden routing behavior.
- Maintain compatibility with existing `php-script` / `application/x-httpd-php` handling.
- Do not add trust/gating logic for `X-Forwarded-*`/`X-Real-IP` inside mod_apex; that decision belongs in `mod_remoteip` or the application/framework layer (see [README.md](README.md#trusted-proxy--forwarded-headers)). mod_apex intentionally exposes all incoming headers to PHP as `$_SERVER['HTTP_*']`, matching mod_php/PHP-FPM behavior.
- `ApexVerboseErrors` (default `Off`) gates whether the fatal-error page includes internal diagnostic detail; keep the default generic body in mind when touching `apex_send_fatal_error_page`.

## Known Pitfalls In This Repo
- `config.m4` appears stale and references `mod_flux`; treat it as historical unless the task explicitly targets extension build tooling.
- For `config.m4` tasks, follow the dedicated instruction: [.github/instructions/config-m4-legacy-handling.instructions.md](.github/instructions/config-m4-legacy-handling.instructions.md)
- Header handling in [mod_apex.c](mod_apex.c) is performance-sensitive and correctness-critical; validate carefully when changing it.
- A C block comment containing a literal `*/` inside descriptive text (e.g. "X-Forwarded-*/X-Real-IP") terminates the comment early and breaks compilation; always add a space between `*` and `/` in such comments.
- A previous fix that gated proxy-header (`X-Forwarded-*`/`X-Real-IP`) registration behind a trusted-subnet check was reverted: it ran after the generic header-passthrough loop that already set the same `$_SERVER` values unconditionally, so the gate was a no-op. Don't reintroduce header-trust logic in mod_apex itself.
- OPcache is unconditionally disabled under the stock `"embed"` SAPI name (hardcoded allowlist in PHP's own `accel_find_sapi()`) -- this is why mod_apex overrides `php_embed_module.name` to `"apache2handler"` in `apex_post_config`. See [README.md](README.md#opcache-support) for the full explanation and measured impact (~11-16x WordPress throughput improvement). If OPcache regresses again (`opcache_get_status()` returns `false`), check this override wasn't accidentally reverted before assuming a deeper problem.

## Where To Read More
- High-level and build notes: [README.md](README.md)
- Apache runtime config example: [httpd.conf](httpd.conf)
- Build helper script: [build-install.sh](build-install.sh)

## Phase Tracking
- Implementation sequence index: [docs/phases/README.md](docs/phases/README.md)
- Phase 1 plan: [docs/phases/PHASE-1-safe-refactor.md](docs/phases/PHASE-1-safe-refactor.md)
- Phase 2 plan: [docs/phases/PHASE-2-correctness-hardening.md](docs/phases/PHASE-2-correctness-hardening.md)
- Phase 3 plan: [docs/phases/PHASE-3-performance-optimization.md](docs/phases/PHASE-3-performance-optimization.md)
