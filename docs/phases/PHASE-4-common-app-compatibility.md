# Phase 4: Common PHP App Compatibility

## Status
In Progress

## Objective
Improve runtime compatibility with common PHP applications (WordPress, Laravel, Symfony, Drupal, Composer tooling paths) while preserving Phase 1-3 stability and performance work.

## Scope
- Ensure robust `$_SERVER` population expected by mainstream frameworks.
- Close common CGI/FastCGI-equivalent metadata gaps at the SAPI boundary.
- Keep compatibility changes minimal and measurable.

## Non-Goals
- No framework-specific hacks.
- No routing model rewrite.
- No behavior regressions in existing GET/POST/header/status handling.

## Work Items
1. Populate `$_SERVER` from Apache common/CGI vars via SAPI callback. (Completed)
2. Validate key server variables used by common apps (`REQUEST_URI`, `SCRIPT_FILENAME`, `DOCUMENT_ROOT`, `HTTP_HOST`, auth headers). (Completed)
3. Verify front-controller style requests and rewritten paths remain correct. (Completed)
4. Add a compatibility smoke checklist for future regressions. (Completed)

## Phase 4 Iteration 1 (Completed)
- Added `register_server_variables` callback in [mod_apex.c](../../mod_apex.c).
- Callback now uses Apache's `ap_add_common_vars(...)` and `ap_add_cgi_vars(...)`, then exports `subprocess_env` into PHP `$_SERVER`.

### Validation Snapshot
- Build/install and restart succeeded.
- Existing smoke checks stayed green (`$_GET` and `$_POST` behavior unchanged).
- `$_SERVER` now includes common app-critical keys (verified via probe endpoint):
	- `REQUEST_METHOD`, `REQUEST_URI`, `QUERY_STRING`
	- `SCRIPT_FILENAME`, `SCRIPT_NAME`, `DOCUMENT_ROOT`
	- `SERVER_PROTOCOL`, `HTTP_HOST`
	- `REMOTE_ADDR`, `REMOTE_PORT`, `SERVER_ADDR`, `SERVER_PORT`
	- POST metadata `CONTENT_TYPE` and `CONTENT_LENGTH`
- `wrk -t2 -c100 -d15s http://127.0.0.1/test.php` remained stable (~28.6k req/s in validation run).

## Phase 4 Iteration 2 (Completed)
- Added compatibility-focused `$_SERVER` enrichment in [mod_apex.c](../../mod_apex.c):
	- `REQUEST_SCHEME`, `HTTPS`, `SERVER_NAME`
	- `REMOTE_USER` when available
	- explicit auth mapping: `HTTP_AUTHORIZATION`, `AUTH_TYPE`, `PHP_AUTH_USER`, `PHP_AUTH_PW` (Basic)
	- explicit proxy header passthrough: `HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_HOST`, `HTTP_X_FORWARDED_PORT`, `HTTP_X_FORWARDED_FOR`, `HTTP_X_REAL_IP`
- Verified front-controller style `PATH_INFO` behavior (`/script.php/foo/bar`) remains available.

### Validation Snapshot
- Basic auth request exposes expected auth variables for app middleware/guards.
- Forwarded header request exposes expected proxy variables.
- Front-controller style request exposes `PATH_INFO` and correct script metadata.
- Throughput sanity check remained stable (`wrk -t2 -c100 -d15s` ~28.2k req/s).

## Compatibility Smoke Checklist
1. GET request to probe endpoint confirms: `REQUEST_URI`, `SCRIPT_FILENAME`, `SCRIPT_NAME`, `DOCUMENT_ROOT`, `HTTP_HOST`, `SERVER_NAME`.
2. POST request confirms: `CONTENT_TYPE`, `CONTENT_LENGTH`, `$_POST` parsing still correct.
3. Basic auth request confirms: `HTTP_AUTHORIZATION`, `AUTH_TYPE=Basic`, `PHP_AUTH_USER`, `PHP_AUTH_PW`.
4. Forwarded-header request confirms: `HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_HOST`, `HTTP_X_FORWARDED_FOR`, `HTTP_X_REAL_IP`.
5. Front-controller path request (`/script.php/foo/bar`) confirms: `PATH_INFO` is present.
6. Performance sanity check: `wrk -t2 -c100 -d15s http://127.0.0.1/test.php` completes without crash signatures.

## Phase 4 Iteration 3 (Completed)
- Added reusable framework-compatibility probe script: [probes/common-app-probe.php](../../probes/common-app-probe.php).
- Probe reports common `$_SERVER` keys and app-oriented checks:
	- front-controller metadata
	- basic-auth mapping
	- proxy-forwarded header visibility
	- `PATH_INFO` handling for `/script.php/...` style routes

### Validation Snapshot
- Basic auth scenario verified: `HTTP_AUTHORIZATION`, `AUTH_TYPE`, `PHP_AUTH_USER`, `PHP_AUTH_PW`.
- Forwarded-header scenario verified: `HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_HOST`, `HTTP_X_FORWARDED_FOR`, `HTTP_X_REAL_IP`.
- Front-controller style request verified: `PATH_INFO` present and correct.
- Performance sanity remained stable (`wrk -t2 -c100 -d15s` ~28.3k req/s).

## Phase 4 Iteration 4 (Completed)
- Added automated compatibility smoke runner: [tools/common_app_compat_smoke.sh](../../tools/common_app_compat_smoke.sh).
- Runner deploys [probes/common-app-probe.php](../../probes/common-app-probe.php), executes compatibility request shapes, and returns non-zero on failures.

### Validation Snapshot
- Full automated checklist passed (`PASS=18 FAIL=0`) after content metadata compatibility fix (`CONTENT_TYPE`/`CONTENT_LENGTH` in `$_SERVER`).
- Includes checks for GET/POST metadata, basic auth mapping, forwarded headers, and front-controller `PATH_INFO`.

### Validation Plan
- Build/install with [build-install.sh](../../build-install.sh).
- Verify smoke script and print selected `$_SERVER` keys.
- Run baseline benchmark (`wrk -t2 -c100 -d15s`) to confirm no major throughput regression.

## Acceptance Criteria
- Common app bootstrap paths no longer fail due to missing `$_SERVER` keys.
- Existing phase 2 correctness checks remain green.
- No new crash signatures or coredumps.

## Rollback Plan
- Keep compatibility changes isolated to SAPI variable registration.
- Revert iteration units independently if regressions appear.