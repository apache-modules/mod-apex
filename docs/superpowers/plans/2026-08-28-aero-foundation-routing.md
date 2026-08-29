# Aero Foundation and Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap `/home/bode/sites/mod_aero` as an independent repository and build a testable Aero foundation that strictly validates `aero.toml`, compiles immutable route decisions, and loads as a non-claiming Apache DSO without changing `mod_apex` behavior.

**Architecture:** Aero lives in a standalone Git repository; the Apex repository is a read-only migration reference. Pure C manifest and route modules have no Apache or PHP dependency. A thin Apache adapter owns the `AeroApplication` directive, validates the manifest during configuration, and always returns `DECLINED` during this phase. A pinned, vendored `tomlc17` parser handles TOML syntax; Aero performs all schema and path validation itself.

**Tech Stack:** C99, Apache HTTP Server 2.4 DSO interface, APR pools in the adapter only, `apxs`, Bash test drivers, vendored `tomlc17` at commit `64a063b8636a4b48d142f978270f5e53e605e240` under the MIT License.

**Spec:** `/home/bode/sites/mod_apex/docs/superpowers/specs/2026-08-28-aero-native-runtime-design.md` until Task 0 copies it into the new repository; afterward use `docs/superpowers/specs/2026-08-28-aero-native-runtime-design.md`.

## Global Constraints

- Product copy uses “Aero Runtime for Apache”; never “Apache Aero” or “PHP Aero.”
- Module file is `mod_aero.so`; Apache symbol is `aero_module`; directive is `AeroApplication`.
- PHP remains 8.4+ ZTS with embed SAPI in later plans; this foundation does not initialize or link PHP.
- Apache 2.4 with event MPM remains the target runtime.
- One manifest represents one dynamic Aero application per Apache instance or container.
- Execute implementation tasks from `/home/bode/sites/mod_aero`.
- Treat `/home/bode/sites/mod_apex` as read-only; Aero may inspect it but must not modify or depend on it.
- The current `mod_apex.c`, build, packages, image, directives, and runtime behavior remain untouched.
- `mod_aero` must return `DECLINED` for every request in this phase.
- Proxy trust remains outside Aero in `mod_remoteip` or the application.
- Unknown manifest keys and inactive-mode keys are configuration errors.
- No runtime request may parse or reopen `aero.toml`.

---

## Locked File Structure

```text
Makefile
AGENTS.md
LICENSE
NOTICE
README.md
include/
  aero_manifest.h
  aero_routes.h
src/
  apache_adapter.c
  manifest.c
  mod_aero.c
  route_matcher.c
tests/
  fixtures/
    compatibility-valid.toml.in
    native-valid.toml.in
  test_manifest.c
  test_routes.c
  test_support.h
vendor/
  tomlc17/
    LICENSE
    tomlc17.c
    tomlc17.h
tools/
  build_aero.sh
  test_aero_foundation.sh
docs/superpowers/
  specs/2026-08-28-aero-native-runtime-design.md
  plans/2026-08-28-aero-runtime-roadmap.md
  plans/2026-08-28-aero-foundation-routing.md
```

`include` contains internal interfaces, `src` contains implementation, `tests`
builds standalone native test binaries, and `vendor` contains only pinned
dependency files and their licenses. No path is shared with or loaded from the
Apex repository.

### Task 0: Bootstrap the standalone repository

**Files:**
- Create: `/home/bode/sites/mod_aero/.gitignore`
- Create: `/home/bode/sites/mod_aero/AGENTS.md`
- Create: `/home/bode/sites/mod_aero/LICENSE`
- Create: `/home/bode/sites/mod_aero/NOTICE`
- Create: `/home/bode/sites/mod_aero/README.md`
- Copy: the approved Aero spec and both Aero plans into `/home/bode/sites/mod_aero/docs/superpowers/`

**Interfaces:**
- Consumes: `/home/bode/sites/mod_apex` only as a read-only source for the approved design documents and Apache-2.0 license text.
- Produces: an independent Git repository with its own identity, instructions, history, and release boundary.

- [ ] **Step 1: Verify repository boundaries before creating anything**

Run:

```bash
test -d /home/bode/sites/mod_apex/.git
if [[ -e /home/bode/sites/mod_aero ]]; then
  [[ -d /home/bode/sites/mod_aero ]]
  [[ -z "$(find /home/bode/sites/mod_aero -mindepth 1 -maxdepth 1 -print -quit)" ]]
fi
git -C /home/bode/sites/mod_apex status --short
```

Expected: the Apex repository exists; the Aero path is either absent or an
empty directory; and the last command records any pre-existing Apex work that
must remain untouched. Stop if the Aero path contains any file or Git history;
do not overwrite it.

- [ ] **Step 2: Initialize the independent Aero repository**

Run:

```bash
mkdir -p /home/bode/sites/mod_aero
git -C /home/bode/sites/mod_aero init -b main
mkdir -p /home/bode/sites/mod_aero/docs/superpowers/specs
mkdir -p /home/bode/sites/mod_aero/docs/superpowers/plans
cp /home/bode/sites/mod_apex/LICENSE /home/bode/sites/mod_aero/LICENSE
cp /home/bode/sites/mod_apex/docs/superpowers/specs/2026-08-28-aero-native-runtime-design.md \
  /home/bode/sites/mod_aero/docs/superpowers/specs/
cp /home/bode/sites/mod_apex/docs/superpowers/plans/2026-08-28-aero-runtime-roadmap.md \
  /home/bode/sites/mod_aero/docs/superpowers/plans/
cp /home/bode/sites/mod_apex/docs/superpowers/plans/2026-08-28-aero-foundation-routing.md \
  /home/bode/sites/mod_aero/docs/superpowers/plans/
```

- [ ] **Step 3: Add repository identity and safety instructions**

Create `NOTICE` containing exactly:

```text
Aero Runtime for Apache
Copyright 2026 Aero Runtime contributors

This product is an independent third-party module for use with the Apache HTTP
Server. It is not an Apache Software Foundation project.
```

Create `.gitignore` containing exactly:

```gitignore
/.libs/
/build/
*.la
*.lo
*.o
*.slo
*.so
```

Create `README.md` stating that Aero Runtime for Apache is an experimental,
standalone project that does not execute PHP yet and is not ready to replace
the released `mod_apex`. Do not include installation or performance claims.

Create `AGENTS.md` with these repository rules:

- Use “Aero Runtime for Apache”; never imply Apache Software Foundation or PHP project ownership.
- Treat `/home/bode/sites/mod_apex` as read-only reference material; never build against it or edit it from an Aero task.
- Target Apache 2.4 event MPM and PHP 8.4+ ZTS embed for runtime phases.
- Keep a persistent runtime bound to its owning Apache worker thread.
- Poison and recycle a child whenever cleanup cannot prove the runtime reusable.
- Keep forwarded-header trust policy in `mod_remoteip` or the application.
- Develop behavior test-first and keep commits limited to one plan task.
- Never install into or restart the host's live Apache from tests.

- [ ] **Step 4: Verify independence and commit the bootstrap**

Run:

```bash
git -C /home/bode/sites/mod_aero status --short
git -C /home/bode/sites/mod_aero add .gitignore AGENTS.md LICENSE NOTICE README.md docs
git -C /home/bode/sites/mod_aero diff --cached --check
git -C /home/bode/sites/mod_aero commit -m "chore: bootstrap standalone Aero repository"
git -C /home/bode/sites/mod_apex status --short
```

Expected: Aero has one root commit, and the final Apex status is identical to
the status recorded in Step 1.

### Task 1: Route decision interface and matcher

**Files:**
- Create: `include/aero_routes.h`
- Create: `src/route_matcher.c`
- Create: `tests/test_support.h`
- Create: `tests/test_routes.c`
- Create: `Makefile`

**Interfaces:**
- Consumes: No project interface.
- Produces: `aero_route_kind`, `aero_route_pattern`, `aero_routes`, `aero_routes_validate()`, and `aero_routes_match()` with the exact declarations below.

- [ ] **Step 1: Define the failing route tests**

Create `tests/test_support.h`:

```c
#ifndef AERO_TEST_SUPPORT_H
#define AERO_TEST_SUPPORT_H

#include <stdio.h>
#include <stdlib.h>

#define ASSERT_TRUE(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "%s:%d assertion failed: %s\n", __FILE__, __LINE__, #expr); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

#define ASSERT_EQ_INT(expected, actual) \
    ASSERT_TRUE((int) (expected) == (int) (actual))

#endif
```

Create `tests/test_routes.c` with cases proving:

```c
#include "aero_routes.h"
#include "test_support.h"
#include <string.h>

static void exact_and_prefix_routes_match(void)
{
    const aero_route_pattern dynamic[] = {{"/", 0}, {"/api/", 1}};
    const aero_route_pattern static_routes[] = {{"/favicon.ico", 0}, {"/assets/", 1}};
    const aero_routes routes = {dynamic, 2, static_routes, 2};
    ASSERT_EQ_INT(AERO_ROUTE_APPLICATION, aero_routes_match(&routes, "/"));
    ASSERT_EQ_INT(AERO_ROUTE_APPLICATION, aero_routes_match(&routes, "/api/orders"));
    ASSERT_EQ_INT(AERO_ROUTE_STATIC, aero_routes_match(&routes, "/assets/app.css"));
    ASSERT_EQ_INT(AERO_ROUTE_STATIC, aero_routes_match(&routes, "/favicon.ico"));
    ASSERT_EQ_INT(AERO_ROUTE_DECLINED, aero_routes_match(&routes, "/other"));
}

static void segment_prefix_does_not_overmatch(void)
{
    const aero_route_pattern dynamic[] = {{"/api/", 1}};
    const aero_routes routes = {dynamic, 1, NULL, 0};
    ASSERT_EQ_INT(AERO_ROUTE_DECLINED, aero_routes_match(&routes, "/apix"));
}

static void conflicting_routes_are_rejected(void)
{
    char error[256] = {0};
    const aero_route_pattern dynamic[] = {{"/assets/", 1}};
    const aero_route_pattern static_routes[] = {{"/assets/app.css", 0}};
    const aero_routes routes = {dynamic, 1, static_routes, 1};
    ASSERT_TRUE(!aero_routes_validate(&routes, error, sizeof(error)));
    ASSERT_TRUE(strstr(error, "overlap") != NULL);
}

int main(void)
{
    exact_and_prefix_routes_match();
    segment_prefix_does_not_overmatch();
    conflicting_routes_are_rejected();
    return EXIT_SUCCESS;
}
```

- [ ] **Step 2: Run the route test and verify it fails**

Run:

```bash
make test-routes
```

Expected: compilation fails because `aero_routes.h` does not exist.

- [ ] **Step 3: Add the route interface**

Create `include/aero_routes.h`:

```c
#ifndef AERO_ROUTES_H
#define AERO_ROUTES_H

#include <stddef.h>

typedef enum {
    AERO_ROUTE_DECLINED = 0,
    AERO_ROUTE_STATIC,
    AERO_ROUTE_APPLICATION
} aero_route_kind;

typedef struct {
    const char *text;
    int is_prefix;
} aero_route_pattern;

typedef struct {
    const aero_route_pattern *dynamic;
    size_t dynamic_count;
    const aero_route_pattern *static_routes;
    size_t static_count;
} aero_routes;

int aero_routes_validate(const aero_routes *routes, char *error, size_t error_size);
aero_route_kind aero_routes_match(const aero_routes *routes, const char *path);

#endif
```

Implement `src/route_matcher.c` with these exact rules:

- Exact patterns match byte-for-byte.
- Manifest suffix `/*` is compiled to a prefix ending in `/`; the stored
  `aero_route_pattern.text` never contains `*`.
- Prefix matching uses the full stored prefix, so `/api/` does not match
  `/apix`.
- Duplicate patterns are rejected.
- A static and dynamic exact match is rejected.
- A prefix overlapping an exact route or another prefix across route kinds is
  rejected.
- Within one route kind, a prefix shadowing another pattern is rejected.
- Invalid or missing arguments return `AERO_ROUTE_DECLINED` and never crash.

- [ ] **Step 4: Add the standalone Makefile target**

Create `Makefile`:

```make
CC ?= cc
CPPFLAGS += -Iinclude -Itests -Ivendor/tomlc17
CFLAGS ?= -std=c99 -O2 -g -Wall -Wextra -Werror -pedantic

.PHONY: test test-routes test-manifest clean

test: test-routes test-manifest

test-routes: build/test_routes
	./build/test_routes

build/test_routes: tests/test_routes.c src/route_matcher.c include/aero_routes.h tests/test_support.h
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_routes.c src/route_matcher.c -o $@

test-manifest: build/test_manifest
	./build/test_manifest

clean:
	rm -rf build
```

Do not add a `build/test_manifest` recipe until Task 3 creates its inputs.
Temporarily make `test` depend only on `test-routes`; Task 3 replaces that line
with the final dependency shown above.

- [ ] **Step 5: Run the route test**

Run: `make test-routes`

Expected: exit 0 with no sanitizer or assertion output.

- [ ] **Step 6: Commit the route module**

```bash
git add include/aero_routes.h src/route_matcher.c \
  tests/test_support.h tests/test_routes.c Makefile
git commit -m "feat(aero): add immutable route matcher"
```

### Task 2: Pin and vendor the TOML parser

**Files:**
- Create: `vendor/tomlc17/LICENSE`
- Create: `vendor/tomlc17/tomlc17.c`
- Create: `vendor/tomlc17/tomlc17.h`
- Create: `vendor/tomlc17/UPSTREAM`
- Modify: `NOTICE`

**Interfaces:**
- Consumes: `tomlc17` upstream commit `64a063b8636a4b48d142f978270f5e53e605e240`.
- Produces: A repository-local TOML parser whose source and license are fixed and auditable.

- [ ] **Step 1: Download only the pinned upstream files**

Run:

```bash
mkdir -p vendor/tomlc17
base=https://raw.githubusercontent.com/cktan/tomlc17/64a063b8636a4b48d142f978270f5e53e605e240
curl -fL "$base/src/tomlc17.c" -o vendor/tomlc17/tomlc17.c
curl -fL "$base/src/tomlc17.h" -o vendor/tomlc17/tomlc17.h
curl -fL "$base/LICENSE" -o vendor/tomlc17/LICENSE
```

Create `vendor/tomlc17/UPSTREAM` containing exactly:

```text
Repository: https://github.com/cktan/tomlc17
Commit: 64a063b8636a4b48d142f978270f5e53e605e240
License: MIT
Files: src/tomlc17.c, src/tomlc17.h, LICENSE
```

- [ ] **Step 2: Verify the dependency identity and compile it**

Run:

```bash
grep -F 'MIT License' vendor/tomlc17/LICENSE
grep -F '64a063b8636a4b48d142f978270f5e53e605e240' vendor/tomlc17/UPSTREAM
cc -std=c99 -Wall -Wextra -Werror -pedantic -c \
  vendor/tomlc17/tomlc17.c -o /tmp/aero-tomlc17.o
```

Expected: all commands exit 0.

- [ ] **Step 3: Record the vendored notice**

Append this paragraph to `NOTICE`:

```text
This product includes tomlc17 by CK Tan, licensed under the MIT License.
The complete license is provided at vendor/tomlc17/LICENSE.
```

- [ ] **Step 4: Commit the pinned parser**

```bash
git add vendor/tomlc17 NOTICE
git commit -m "build(aero): vendor pinned TOML parser"
```

### Task 3: Strict manifest schema and path validation

**Files:**
- Create: `include/aero_manifest.h`
- Create: `src/manifest.c`
- Create: `tests/test_manifest.c`
- Create: `tests/fixtures/native-valid.toml.in`
- Create: `tests/fixtures/compatibility-valid.toml.in`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `aero_routes_validate()` and vendored `tomlc17`.
- Produces: `aero_mode`, `aero_manifest`, `aero_manifest_load()`, and `aero_manifest_free()`.

- [ ] **Step 1: Define the manifest interface**

Create `include/aero_manifest.h`:

```c
#ifndef AERO_MANIFEST_H
#define AERO_MANIFEST_H

#include "aero_routes.h"
#include <stddef.h>
#include <stdint.h>

typedef enum {
    AERO_MODE_NATIVE = 1,
    AERO_MODE_COMPATIBILITY
} aero_mode;

typedef struct {
    char *name;
    char *root;
    char *bootstrap;
    char *front_controller;
    aero_mode mode;
    uint64_t max_requests;
    uint64_t max_age_seconds;
    uint64_t process_memory_recycle_bytes;
    uint64_t request_timeout_ms;
    uint64_t max_body_bytes;
    uint32_t max_concurrent_streams;
    char *live_path;
    char *ready_path;
    aero_route_pattern *dynamic_routes;
    size_t dynamic_count;
    aero_route_pattern *static_routes;
    size_t static_count;
    aero_routes routes;
} aero_manifest;

int aero_manifest_load(const char *path, aero_manifest **out,
                       char *error, size_t error_size);
void aero_manifest_free(aero_manifest *manifest);

#endif
```

- [ ] **Step 2: Write fixtures and failing tests**

Create `native-valid.toml.in` with the approved spec values and an `@ROOT@`
token wherever the temporary absolute application root is required. Create
`compatibility-valid.toml.in` with `application.mode = "compatibility"`, no
`bootstrap`, `compatibility.front_controller = "public/index.php"`, and the
same `@ROOT@` token.

Create `tests/test_manifest.c` to create a temporary directory containing real
bootstrap/front-controller files, replace every `@ROOT@` token with that
directory's canonical absolute path, and write the materialized manifest into
the temporary directory before asserting:

```c
ASSERT_TRUE(aero_manifest_load(path, &manifest, error, sizeof(error)));
ASSERT_EQ_INT(AERO_MODE_NATIVE, manifest->mode);
ASSERT_TRUE(strcmp(manifest->name, "storefront") == 0);
ASSERT_TRUE(manifest->max_requests == 10000);
ASSERT_TRUE(manifest->max_age_seconds == 1800);
ASSERT_TRUE(manifest->process_memory_recycle_bytes == 805306368);
ASSERT_TRUE(manifest->request_timeout_ms == 30000);
ASSERT_TRUE(manifest->max_body_bytes == 33554432);
ASSERT_EQ_INT(AERO_ROUTE_APPLICATION,
              aero_routes_match(&manifest->routes, "/api/orders"));
```

Add separate negative cases for:

- Unknown top-level table and unknown key in every accepted table
- Relative manifest path
- Relative `application.root`
- Missing root, bootstrap, or front controller
- Native mode with `compatibility.front_controller`
- Compatibility mode with `application.bootstrap`
- Invalid duration, byte-size, integer, and route values
- A canonical bootstrap/front-controller path escaping the root via `..` or a
  symlink
- Duplicate and overlapping static/dynamic routes
- Health paths that do not start with `/` or overlap application routes

- [ ] **Step 3: Run the manifest test and verify it fails**

Run: `make test-manifest`

Expected: build fails because `manifest.c` and the manifest test recipe are not
implemented.

- [ ] **Step 4: Implement strict parsing**

Implement `aero_manifest_load()` with these rules:

- Parse using `toml_parse_file_ex()`.
- Accept only tables `application`, `routes`, `runtime`, `health`, and
  `compatibility`.
- Enumerate every table and reject keys outside the spec; do not silently ignore
  forward-looking settings.
- Require absolute manifest and root paths.
- Canonicalize existing root and entry-point files with `realpath()`.
- Verify entry points remain below the canonical root using a separator-aware
  prefix check.
- Parse duration suffixes `ms`, `s`, and `m` with checked `uint64_t` arithmetic.
- Parse byte suffixes `K`, `M`, and `G` as powers of 1024 with checked
  arithmetic.
- Compile exact routes unchanged and `/*` routes as slash-terminated prefixes.
- Reject `*` anywhere except the final `/*` suffix.
- Transfer all values to owned heap allocations before `toml_free()`.
- On every failure, free partial state, leave `*out == NULL`, and write one
  actionable error into the caller's buffer.

`aero_manifest_free()` must accept `NULL` and free every owned string, route
string, route array, and the manifest exactly once.

- [ ] **Step 5: Complete the Makefile and run tests under sanitizers**

Add:

```make
build/test_manifest: tests/test_manifest.c src/manifest.c src/route_matcher.c \
  vendor/tomlc17/tomlc17.c include/aero_manifest.h include/aero_routes.h \
  tests/test_support.h tests/fixtures/native-valid.toml.in \
  tests/fixtures/compatibility-valid.toml.in
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_manifest.c src/manifest.c \
	  src/route_matcher.c vendor/tomlc17/tomlc17.c -o $@
```

Run:

```bash
make clean test
make clean test CFLAGS='-std=c99 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined -fno-omit-frame-pointer'
```

Expected: both route and manifest tests exit 0; sanitizers report no findings.

- [ ] **Step 6: Commit the manifest module**

```bash
git add include/aero_manifest.h src/manifest.c tests \
  Makefile
git commit -m "feat(aero): validate application manifests"
```

### Task 4: Non-claiming Apache module shell

**Files:**
- Create: `src/mod_aero.c`
- Create: `src/apache_adapter.c`
- Create: `include/aero_apache.h`
- Create: `tools/build_aero.sh`

**Interfaces:**
- Consumes: `aero_manifest_load()` and `aero_manifest_free()`.
- Produces: Apache symbol `aero_module`, directive `AeroApplication`, and handler name `aero-application`; the handler always returns `DECLINED` in this plan.

- [ ] **Step 1: Write the build smoke test**

Create `tools/build_aero.sh` expecting these environment variables:

```bash
#!/usr/bin/env bash
set -euo pipefail

APXS=${APXS:-apxs}
INSTALL_MODE=${INSTALL_MODE:-never}

[[ "$INSTALL_MODE" == never ]] || {
    echo 'error: Aero foundation supports build-only INSTALL_MODE=never' >&2
    exit 2
}

"$APXS" -c -n aero \
  -I"$PWD/include" -I"$PWD/vendor/tomlc17" \
  src/mod_aero.c src/apache_adapter.c src/manifest.c \
  src/route_matcher.c vendor/tomlc17/tomlc17.c

test -f src/.libs/mod_aero.so
printf 'Built artifact: src/.libs/mod_aero.so\n'
```

Run: `chmod +x tools/build_aero.sh && ./tools/build_aero.sh`

Expected: fail because the Apache source files do not exist.

- [ ] **Step 2: Add the Apache adapter interface**

Create `include/aero_apache.h` declaring:

```c
#ifndef AERO_APACHE_H
#define AERO_APACHE_H

#include "httpd.h"
#include "http_config.h"

extern module AP_MODULE_DECLARE_DATA aero_module;
void *aero_create_server_config(apr_pool_t *pool, server_rec *server);
void *aero_merge_server_config(apr_pool_t *pool, void *base, void *child);
const char *aero_set_application(cmd_parms *cmd, void *unused, const char *path);
int aero_post_config(apr_pool_t *config_pool, apr_pool_t *log_pool,
                     apr_pool_t *temp_pool, server_rec *server);
int aero_handler(request_rec *request);

#endif
```

- [ ] **Step 3: Implement configuration ownership**

In `apache_adapter.c`, define a private server configuration containing the
configured manifest path and a validated `aero_manifest *`. The directive stores
the path during parsing. If no `AeroApplication` directive exists,
`aero_post_config()` returns `OK` and leaves Aero inactive. Otherwise it loads
exactly one manifest for the effective server configuration, logs `APLOG_CRIT`
and returns `HTTP_INTERNAL_SERVER_ERROR` on failure. Make repeated post-config
invocations safe by releasing any earlier validated manifest before replacing
it. Register an APR pool cleanup that calls `aero_manifest_free()`.

Reject:

- More than one distinct `AeroApplication` in the effective Apache instance
- Relative manifest paths
- Use in directory or `.htaccess` context

`aero_handler()` must contain only the handler guard and:

```c
return DECLINED;
```

It must not match routes, read files, initialize PHP, write headers, or write a
body in this plan.

- [ ] **Step 4: Declare and register the Apache module**

In `mod_aero.c`, define `AeroApplication` with `AP_INIT_TAKE1`, register
`aero_post_config` and `aero_handler`, and declare:

```c
module AP_MODULE_DECLARE_DATA aero_module = {
    STANDARD20_MODULE_STUFF,
    NULL,
    NULL,
    aero_create_server_config,
    aero_merge_server_config,
    aero_commands,
    aero_register_hooks
};
```

- [ ] **Step 5: Build without touching mod_apex**

Run:

```bash
./tools/build_aero.sh
test -f src/.libs/mod_aero.so
APEX_REFERENCE=/home/bode/sites/mod_apex
test -f "$APEX_REFERENCE/mod_apex.c"
git -C "$APEX_REFERENCE" diff --exit-code -- mod_apex.c build-install.sh
```

Expected: all commands exit 0 and the existing module/build script have no diff.

- [ ] **Step 6: Commit the non-claiming module shell**

```bash
git add include/aero_apache.h src/mod_aero.c \
  src/apache_adapter.c tools/build_aero.sh
git commit -m "feat(aero): add non-claiming Apache module shell"
```

### Task 5: Apache configuration integration test

**Files:**
- Create: `tools/test_aero_foundation.sh`
- Create: `tests/fixtures/apache-native.toml.in`

**Interfaces:**
- Consumes: `src/.libs/mod_aero.so` and `AeroApplication`.
- Produces: A disposable Apache syntax/runtime gate proving validation occurs at configuration time and no request is claimed.

- [ ] **Step 1: Create the disposable test driver**

The script must:

1. Require `apache2` or `httpd`, `curl`, and the built Aero DSO.
2. Create a temporary server root with `conf`, `logs`, `run`, `public`, and
   `application` directories.
3. Create a native bootstrap file and materialize an absolute-path manifest.
4. Generate a minimal Apache configuration that loads the platform MPM,
   authentication/core dependencies, `mod_aero.so`, and declares
   `AeroApplication`.
5. Select an unoccupied loopback port.
6. Run the server's `-t` syntax check.
7. Start the disposable server in foreground mode as a background test process.
8. Request a static fixture and assert the response comes from Apache.
9. Stop the exact recorded test PID in a cleanup trap.

Do not call `systemctl`, alter `/etc/apache2`, or signal the user's live Apache.

- [ ] **Step 2: Add failing configuration cases**

For each case, generate a separate manifest/config and assert syntax checking
fails with the expected error fragment:

```text
unknown key
application.root must be absolute
native mode requires application.bootstrap
route overlap
entry point escapes application.root
```

- [ ] **Step 3: Prove runtime non-claiming behavior**

Configure `<Location "/dynamic"> SetHandler aero-application </Location>` and
assert the request is handled by Apache's ordinary fallback, not by Aero:

```bash
code=$(curl -sS -o "$tmp/dynamic.body" -w '%{http_code}' "$base/dynamic")
test "$code" = 404
! grep -q 'Aero' "$tmp/dynamic.body"
```

- [ ] **Step 4: Run the complete foundation gate**

Run:

```bash
make clean test
./tools/build_aero.sh
./tools/test_aero_foundation.sh
git diff --check
```

Expected: all commands exit 0. No command installs or enables the module in the
host Apache configuration.

- [ ] **Step 5: Commit the integration gate**

```bash
git add tools/test_aero_foundation.sh tests/fixtures/apache-native.toml.in
git commit -m "test(aero): validate foundation in disposable Apache"
```

### Task 6: Foundation documentation and phase exit

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-28-aero-runtime-roadmap.md`

**Interfaces:**
- Consumes: The completed foundation behavior.
- Produces: Maintainer instructions that do not advertise unfinished Aero runtime behavior to end users.

- [ ] **Step 1: Document only implemented behavior**

Replace the bootstrap-only `README.md` with these sections:

- Status: experimental foundation; does not execute PHP or claim requests
- Build: `./tools/build_aero.sh`
- Unit tests: `make test`
- Disposable Apache test: `./tools/test_aero_foundation.sh`
- Manifest schema implemented in this phase
- Explicit warning not to install it over `mod_apex`
- Vendored dependency identity and license location

Do not publish end-user installation claims yet, and do not modify the Apex
README, Docker documents, or native package instructions during this phase.

- [ ] **Step 2: Mark only roadmap stage 1 complete**

Change the roadmap's foundation heading to `Foundation and routing — complete`
and leave stages 2–6 unchanged.

- [ ] **Step 3: Run the release-sized foundation verification**

Run:

```bash
make clean test
./tools/build_aero.sh
./tools/test_aero_foundation.sh
bash -n tools/build_aero.sh tools/test_aero_foundation.sh
git diff --check
git -C /home/bode/sites/mod_apex diff --exit-code -- mod_apex.c build-install.sh
git status --short
```

Expected: all gates pass. Only planned files in the standalone Aero repository
are modified or newly tracked. The Apex implementation, packages, Docker files,
and user documentation remain unchanged.

- [ ] **Step 4: Commit the phase exit documentation**

```bash
git add README.md docs/superpowers/plans/2026-08-28-aero-runtime-roadmap.md
git commit -m "docs(aero): complete foundation handoff"
```

## Foundation Exit Criteria

- `aero.toml` syntax and schema failures block Apache configuration.
- Valid manifests produce owned immutable configuration and route decisions.
- Manifest and route modules pass ordinary and ASan/UBSan tests.
- The `mod_aero` DSO builds independently from `mod_apex`.
- `mod_aero` writes no response and returns `DECLINED` for every request.
- Disposable Apache tests never alter or restart the live server.
- No PHP lifecycle code exists in Aero yet.
- The existing `mod_apex` implementation and release paths remain unchanged.
