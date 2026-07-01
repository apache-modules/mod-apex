---
description: "Use when editing Apache module routing, handler logic, SAPI callbacks, or request lifecycle code in mod_apex. Enforces safety and compatibility guardrails for C changes."
name: "Apache Runtime Guardrails"
applyTo:
  - "mod_apex.c"
  - "httpd.conf"
---
# Apache Runtime Guardrails

Apply these rules for changes touching Apache request flow or PHP embed integration.

## Required Approach
- Read [README.md](../../README.md), [AGENTS.md](../../AGENTS.md), and the touched code before proposing changes.
- Keep changes minimal and localized; avoid broad rewrites.
- Preserve currently working behavior unless the task explicitly requires behavior changes.

## Request Lifecycle Invariants
- Keep `php_request_startup()` and `php_request_shutdown()` exactly balanced per request.
- Do not access request-scoped context after `php_request_shutdown()`.
- Preserve thread-local assumptions around `SG(server_context)`.
- Keep handler compatibility for both `php-script` and `application/x-httpd-php` unless explicitly asked otherwise.

## SAPI Callback Rules
- Maintain callback signatures compatible with the current PHP version in use.
- Treat output and header paths as correctness-critical: avoid semantic changes without tests.
- For header operations, verify add/replace/delete/status behavior stays consistent.

## Apache Module Safety
- Keep defensive guards in handlers (`DECLINED` conditions, initial request checks) unless task requires routing change.
- Preserve Apache logging quality for failures and internal errors.
- Avoid introducing global mutable state without synchronization and a clear need.

## Validation Checklist
- Build using the project flow in [build-install.sh](../../build-install.sh).
- Verify module load and handler routing with [httpd.conf](../../httpd.conf).
- Smoke test with [test.php](../../test.php).
- If behavior changed, document what changed and why.
