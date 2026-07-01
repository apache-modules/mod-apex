# Phase 3: Performance Optimization

## Status
In Progress

## Objective
Reduce avoidable memory and CPU overhead on high-concurrency traffic while preserving phase 2 correctness guarantees.

## Scope
- Optimize request-body ingestion path.
- Reduce unnecessary flushes/copies.
- Add lightweight observability for regression detection.

## Non-Goals
- No behavior-changing feature additions.
- No broad architectural rewrite beyond targeted hot paths.

## Work Items
1. Replace whole-body flattening with streaming reads in SAPI `read_post` flow in [mod_apex.c](../../mod_apex.c). (Completed)
2. Avoid redundant flush and copy operations where safe. (Completed)
3. Add inexpensive timing/log points around startup, execute, and shutdown stages. (Completed)
4. Confirm thread-safe behavior remains unchanged under event MPM assumptions. (Completed)

## Phase 3 Iteration 1 (Completed)
- Request body handling now streams directly from Apache in `apex_read_post(...)` instead of pre-buffering entire POST/PUT payloads.
- `apex_prepare_request_context(...)` now only prepares client-block state and known content length metadata.
- Added `APLOG_TRACE1` timing logs in `apex_handler(...)` for startup, execute, and shutdown durations.

### Validation Snapshot
- Build/install succeeded with `./build-install.sh` and `sudo INSTALL_MODE=always ./build-install.sh`.
- Correctness smoke: GET and POST outputs remained correct against [test.php](../../test.php).
- Large body smoke: 200KB form payload returned HTTP 200 with no Apache errors.
- Benchmark (`wrk -t2 -c8 -d10s`) completed without socket errors.
- Benchmark (`wrk -t2 -c100 -d10s`) showed high throughput (~24.7k req/s) but reproducible read socket errors; investigate in a follow-up iteration.

## Phase 3 Iteration 2 (Completed)
- Output callback hardening in [mod_apex.c](../../mod_apex.c):
  - `apex_ub_write(...)` now returns the actual byte count reported by `ap_rwrite(...)`.
  - Removed the unconditional `ap_rflush(...)` call at the end of `apex_handler(...)`.
- Preserved request lifecycle and thread-safety behavior from phase 2.

### Validation Snapshot
- Build/install and Apache restart succeeded.
- GET/POST smoke tests remained correct.
- `wrk -t2 -c8 -d10s http://127.0.0.1/test.php` remained clean.
- `wrk -t2 -c100 -d10s http://127.0.0.1/test.php` still shows read socket errors but no Apache runtime errors and all sampled access statuses are 200.
- Isolation check: `wrk -t2 -c100 -d10s http://127.0.0.1/` (static Apache endpoint) also shows read socket errors on this host, indicating the caveat is likely environment/tooling-level rather than specific to `mod_apex` response handling.

## Phase 3 Iteration 3 (Completed)
- Added low-overhead per-request counters in [mod_apex.c](../../mod_apex.c):
  - `read_post_bytes`: bytes consumed from request body through `apex_read_post(...)`.
  - `ub_write_bytes`: bytes emitted through `apex_ub_write(...)`.
- Included counters in the existing `APLOG_TRACE1` request timing line for targeted diagnostics without changing runtime behavior at normal log levels.

### Validation Snapshot
- Build/install and restart succeeded.
- GET and POST smoke tests remained correct.
- `wrk -t2 -c8 -d10s http://127.0.0.1/test.php` remained clean.
- `wrk -t2 -c100 -d10s http://127.0.0.1/test.php` improved to ~26.85k req/s with read socket errors reduced to ~24.7k on this run; Apache error log stayed empty.

## Phase 3 Iteration 4 (Completed)
- Added a startup safety guard in [mod_apex.c](../../mod_apex.c) to require a threaded MPM before PHP engine initialization in `apex_child_init(...)`.
- Goal: prevent unsafe initialization paths when Apache is launched in atypical non-threaded/debug modes.

### Validation Snapshot
- Build/install and threaded service-mode smoke remained healthy.
- Bounded `apachectl -X` run with request traffic did not crash during the validation window.
- No new files appeared in `/var/lib/apache2/coredumps` during this pass.
- Historical terminal exit 139 remains noted, but was not reproduced after this hardening pass.

## Phase 3 Iteration 5 (Completed)
- Executed a dedicated closure loop for `apachectl -X` reproducibility:
  - 8 bounded attempts (`timeout 12s`) while driving request traffic to `/test.php`.
  - Recorded timeout status, HTTP 200 counts, and core-file count after each attempt.

### Validation Snapshot
- All 8 attempts exited by timeout (`124`), with successful request handling observed each time.
- Core-file count remained unchanged across the full run (no new files in `/var/lib/apache2/coredumps`).
- Service-mode Apache restart after the loop succeeded.

### Current Conclusion
- Based on current code, the prior `apachectl -X` exit `139` is not reproducible in repeated bounded runs.
- Keep the MPM safety guard in place and treat any future `139` as a separate environment/runtime incident unless reproduced with fresh artifacts.

## Phase 3 Iteration 6 (Completed)
- Applied high-load Apache runtime tuning for live system configuration (`/etc/apache2`) to stabilize 100+ connection benchmarks.
- MPM and keepalive tuning were documented for operations handoff in [README.md](../../README.md).

### Validation Snapshot
- Syntax check passed and Apache restart succeeded.
- `wrk -t2 -c100 -d15s http://127.0.0.1/test.php` completed without a socket error line in this run.
- `wrk -t2 -c100 -d15s http://127.0.0.1/` showed dramatically lower read socket errors compared to prior runs.

## Benchmark Plan
- Baseline and compare using workload from [README.md](../../README.md):
  - `wrk -t2 -c100 -d10s http://localhost/test.php`
- Add one larger request-body scenario to validate memory behavior.

## Acceptance Criteria
- Equal or better throughput/latency under baseline workload.
- Lower memory pressure on larger POST/PUT bodies.
- No regressions in correctness tests from phase 2.

## Rollback Plan
- Keep each optimization isolated and measurable.
- Revert only failing optimization units, preserving correctness fixes.
