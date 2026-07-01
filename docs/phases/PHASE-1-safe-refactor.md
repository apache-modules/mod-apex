# Phase 1: Safe Internal Refactor (No Behavior Change)

## Status
- State: Completed
- Updated: 2026-05-22
- Summary: Internal helper extraction is implemented in mod_apex.c and runtime smoke now passes. Root cause for prior worker crashes was missing TSRM worker-thread context before `php_request_startup()`; explicit context attachment is now performed before request startup.

## Progress Checklist
- [x] Introduce internal helper functions for handler decomposition
- [x] Keep callback signatures and hook registration stable for current PHP target
- [x] Keep SG(server_context) request-scoped
- [x] Preserve handler guards and logging paths
- [x] Build smoke passes with local artifact generation
- [x] Privileged install and active Apache module-load verification
- [x] Smoke test against repo test endpoint under active mod_apex routing

## Current Blocker
- Resolved in this cycle.
- Fix applied in [mod_apex.c](../../mod_apex.c): explicit worker-thread TSRM context attachment via `ts_resource_ex(...)` (core/sapi/executor/compiler globals) before `php_request_startup()`.
- Validation:
   - Build/install via [build-install.sh](../../build-install.sh) succeeded.
   - `curl -i --max-time 10 http://127.0.0.1/test.php` returns `200 OK` with body `ok`.
   - `curl -i --max-time 10 -X POST ... http://127.0.0.1/test.php` returns `200 OK` with body `ok`.
   - No new worker segfault cores were generated after the fixed build was deployed.

## Objective
Improve maintainability and reviewability by separating request adaptation, PHP execution, and response finalization while preserving existing runtime behavior.

## Scope
- Refactor internal structure in [mod_apex.c](../../mod_apex.c).
- Keep handler routing behavior unchanged.
- Keep startup/execute/shutdown sequence unchanged.

## Non-Goals
- No semantic changes to header behavior yet.
- No POST body streaming changes yet.
- No performance micro-optimizations yet.

## Work Items
1. Introduce internal helper functions in [mod_apex.c](../../mod_apex.c):
   - `apex_is_supported_handler(request_rec *r)`
   - `apex_prepare_request_context(request_rec *r, apex_ctx_t *ctx)`
   - `apex_populate_php_request_info(request_rec *r, apex_ctx_t *ctx)`
   - `apex_execute_php_file(request_rec *r)`
2. Keep existing callback signatures and hook registrations unchanged.
3. Ensure `SG(server_context)` assignment remains request-scoped.
4. Preserve all current guard checks and error logging paths.

## Validation
- Build using [build-install.sh](../../build-install.sh).
- Verify Apache module load with [httpd.conf](../../httpd.conf).
- Run smoke request against [test.php](../../test.php).
- Confirm no expected response behavior change for basic GET/POST.

## Operator Runbook (Root Required)
Use this sequence to close remaining Phase 1 validation gates on a Debian Apache host.

1. Install and enable module:
   - `cd /home/bode/sites/mod_apex`
   - `sudo INSTALL_MODE=always ./build-install.sh`
2. Disable conflicting PHP execution paths (keep core Apache modules enabled):
   - `sudo a2dismod aero proxy_fcgi || true`
   - `sudo a2dissite aero phpfpm-bench || true`
   - `sudo rm -f /etc/apache2/sites-enabled/aero.conf /etc/apache2/sites-enabled/phpfpm-bench.conf`
3. Ensure dynamic linker sees PHP ZTS runtime:
   - `echo '/usr/local/php-zts/lib' | sudo tee /etc/ld.so.conf.d/php-zts.conf >/dev/null`
   - `sudo ldconfig`
4. Route a smoke endpoint from this repo:
   - `sudo install -m 0644 /home/bode/sites/mod_apex/test.php /var/www/html/test.php`
5. Route PHP files to apex in the default vhost:
   - `sudo tee /etc/apache2/conf-available/apex-php-handler.conf >/dev/null <<'EOF'`
   - `<FilesMatch "\\.php$">`
   - `    SetHandler php-script`
   - `</FilesMatch>`
   - `EOF`
   - `sudo a2enconf apex-php-handler`
6. Restart Apache and verify clean module state:
   - `sudo systemctl restart apache2`
   - `apache2ctl -M | grep apex`
   - `apache2ctl -M | grep -E 'aero|proxy_fcgi' && echo 'unexpected module still loaded'`
   - `ls -1 /etc/apache2/sites-enabled | grep -E 'aero|phpfpm-bench' && echo 'unexpected site still enabled'`
7. Run GET/POST smoke:
   - `curl -i --max-time 10 http://127.0.0.1/test.php`
   - `curl -i --max-time 10 -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=1&b=2' http://127.0.0.1/test.php`

## Acceptance Criteria
- Same external behavior before and after refactor.
- Smaller, easier-to-review handler with clear stages.
- No startup/shutdown balancing regressions.

## Rollback Plan
- Revert only helper extraction blocks while keeping original handler body intact.
- Do not touch unrelated files if rollback is needed.
