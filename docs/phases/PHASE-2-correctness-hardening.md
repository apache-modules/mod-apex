# Phase 2: Correctness And Protocol Hardening

## Status
- State: Completed
- Updated: 2026-05-22
- Summary: Header parsing and lifecycle hardening are implemented and validated for common app patterns (Set-Cookie multi-value, Content-Type preservation, replace/delete semantics). Request metadata ordering/body buffering now correctly populate query and form POST superglobals. Status mapping works for standard status codes (for example 404); non-standard 418 currently resolves to 500 under this Apache runtime status table.

## Objective
Fix correctness-sensitive behavior in response/header handling and lifecycle boundaries without changing high-level architecture.

## Scope
- Harden header translation from PHP SAPI to Apache response fields.
- Prevent accidental default-content-type override when application sets headers.
- Add explicit lifecycle cleanup boundaries.

## Non-Goals
- No large performance-focused redesign.
- No async I/O interception.

## Work Items
1. Implement robust header-line parsing for SAPI callback paths in [mod_apex.c](../../mod_apex.c):
   - Correctly parse `Name: Value` header lines.
   - Handle add vs replace semantics.
   - Preserve multi-value headers where required (for example, `Set-Cookie`).
2. Ensure status code mapping is consistent between SAPI status and Apache response status.
3. Remove unconditional default content type assignment; only set fallback if absent.
4. Clear request-local pointers before shutdown boundaries where appropriate.
5. Add targeted comments only around non-obvious correctness logic.

## Validation
- Build and load checks via [build-install.sh](../../build-install.sh) and [httpd.conf](../../httpd.conf).
- HTTP behavior tests:
  - Query-string parsing into `$_GET` (validated)
  - Form-urlencoded parsing into `$_POST` (validated)
  - Standard status codes (validated: 404)
  - Non-standard status behavior (observed: 418 resolves to 500 in current Apache runtime)
  - Multiple `Set-Cookie`
  - Explicit app-defined `Content-Type`
  - Header replace/delete scenarios
- Smoke test [test.php](../../test.php).

## Acceptance Criteria
- Header/status behavior is protocol-correct for common app patterns.
- No request-state leakage across requests.
- No regression in basic PHP script execution.

## Rollback Plan
- Guard new parsing logic in isolated helpers to allow surgical rollback.
- Keep phase-contained commits to revert correctness changes independently.
