---
description: "Use when editing config.m4 or discussing extension build metadata in mod_apex. Clarifies that config.m4 is legacy/stale and should not be refactored unless explicitly requested."
name: "Config.m4 Legacy Handling"
applyTo: "config.m4"
---
# Config.m4 Legacy Handling

This repository primarily builds Apache module artifacts using [build-install.sh](../../build-install.sh) and direct `apxs` commands documented in [README.md](../../README.md).

## Default Behavior
- Treat [config.m4](../../config.m4) as legacy/stale metadata.
- Do not refactor, rename symbols, or "fix" naming drift in `config.m4` unless the user explicitly asks for build-system migration.
- Do not let `config.m4` inconsistencies drive runtime changes in [mod_apex.c](../../mod_apex.c).

## If A Task Explicitly Targets config.m4
- Keep scope strictly to requested build-tooling changes.
- Preserve currently working runtime behavior.
- Document assumptions about `apxs`, APR, and PHP embed linkage.
- Validate generated configuration/build steps before proposing additional cleanup.

## Communication Guidance
- If build breaks but `build-install.sh` works, prioritize the script-based path first.
- Explain that `config.m4` and runtime module code may evolve independently in this repo.
