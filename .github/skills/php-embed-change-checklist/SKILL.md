---
name: php-embed-change-checklist
description: 'Use when modifying mod_apex request lifecycle, SAPI callbacks, Apache handler flow, or thread-safety behavior. Provides a research-first, production-safe checklist for C changes.'
argument-hint: 'Describe the change you plan to make in mod_apex.c'
user-invocable: true
---

# PHP Embed Change Checklist

Use this skill for any non-trivial change in [mod_apex.c](../../../../mod_apex.c).

## Goals
- Preserve currently working behavior unless explicitly asked to change it.
- Prevent request-state leaks, shutdown misuse, and threading regressions.
- Keep patches small, professional, and easy to review.

## Step 1: Research Before Editing
1. Read [AGENTS.md](../../../../AGENTS.md).
2. Read [README.md](../../../../README.md).
3. Locate touched code paths in [mod_apex.c](../../../../mod_apex.c).
4. Write a short intent statement: what changes, what must stay unchanged.

## Step 2: Define Invariants
Confirm these invariants still hold after your change:
- Per-request startup/shutdown are balanced.
- No post-shutdown use of request context.
- `SG(server_context)` lifecycle remains valid.
- Existing handler compatibility remains intact unless requested.

## Step 3: Implement Minimal Patch
1. Edit the smallest possible region.
2. Preserve existing signatures and integration points.
3. Avoid speculative refactors.
4. Add comments only where logic is not obvious.

## Step 4: Validate
1. Build via [build-install.sh](../../../../build-install.sh).
2. Confirm Apache runtime wiring in [httpd.conf](../../../../httpd.conf).
3. Execute smoke test on [test.php](../../../../test.php).
4. If available, run benchmark from [README.md](../../../../README.md) to compare before/after.

## Step 5: Review Output
Report:
- What changed
- What stayed intentionally unchanged
- Any remaining assumptions or risks
- Follow-up tests recommended
