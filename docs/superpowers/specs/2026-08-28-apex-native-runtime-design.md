# Apex Native Runtime Architecture

Date: 2026-08-28

Status: Approved design; implementation not started

## Purpose

This document describes a clean-sheet architecture for a future Apex runtime.
It is not a refactor plan for the current `mod_apex.c`. The design intentionally
introduces an Apex-specific application model to gain throughput, lifecycle
control, and failure isolation while retaining an optional compatibility path
for traditional PHP applications.

The primary goal is to preserve Apex's shortest request path: Apache receives a
dynamic request and executes PHP inside the same Apache worker thread. The
design does not introduce a socket, FastCGI handoff, or separate PHP worker
process.

## Decisions

- One dynamic Apex application runs per Apache instance or container.
- Each Apache child owns one PHP ZTS engine.
- Each Apache worker thread lazily boots one persistent native application
  runtime when it first receives an Apex request.
- Apache serves declared static routes without entering PHP.
- A manifest declares the application, routes, limits, and runtime mode.
- Native applications receive immutable structured requests and return
  structured responses.
- Persistence is explicit and opt-in. Request-scoped state is destroyed after
  every logical request.
- Traditional applications run through a compatibility adapter with a real
  PHP startup/shutdown cycle for every HTTP request.
- Any runtime whose cleanup cannot be proven complete is poisoned. Its Apache
  child drains and exits, and Apache starts a clean replacement.

## Alternatives Considered

### Embedded persistent runtime per Apache thread

This is the selected architecture. It has no inter-process request handoff and
therefore offers the highest potential throughput. A PHP crash or contaminated
runtime is contained to a replaceable Apache child. Its main cost is that each
active PHP-serving thread owns a distinct application runtime and its retained
memory.

### Runtime pool inside each Apache child

A smaller pool of PHP runtimes could reduce memory, but Apache worker threads
would have to wait for runtime leases. The resulting queue, synchronization,
cancellation, and lease-recovery behavior would add latency and create new
deadlock risks. It also conflicts with PHP ZTS's natural per-thread state.

### Separate Apex worker processes

Dedicated runtime processes would improve crash and memory isolation, but they
would reintroduce serialization, queuing, and a process handoff similar to
PHP-FPM. That contradicts Apex's purpose and is not selected.

## System Ownership

Apache continues to own:

- Network connections and HTTP parsing
- TLS
- HTTP/1.1 and HTTP/2 connection handling
- Access control and authentication configured in Apache
- Trusted-proxy handling through `mod_remoteip`
- Static files
- Compression and output filters
- Child and worker-thread management

Apex owns:

- Manifest validation and route selection
- PHP engine and per-thread runtime lifecycle
- Apache-to-Apex request translation
- Native application boot and logical request scopes
- Compatibility-mode SAPI translation
- Response validation and streaming
- Runtime health, poisoning, and recycle decisions
- Apex-specific metrics and diagnostics

## Request Flow

```text
Client
  |
  v
Apache event MPM
  |-- declined route -------> another Apache handler
  |-- static route ---------> Apache file response
  `-- application route
         |
         v
   Per-thread Apex runtime
         |-- immutable request
         |-- request scope
         |-- persistent service registry
         |-- application handler
         `-- response or stream
                 |
                 v
          Apache output filters
```

## Internal Modules

The architecture uses small internal interfaces to hide Apache, PHP, TSRM, and
SAPI complexity. `mod_apex.c` is a composition root rather than the request
implementation.

### Apache adapter

The Apache adapter is the only module that understands Apache hooks and
`request_rec`. It registers hooks, asks the route matcher for a decision,
creates an internal request description, and passes response bytes through
Apache output filters.

### Manifest and route matcher

The manifest module validates application configuration during Apache
configuration checking. The route matcher uses its compiled immutable output
to return exactly one of:

```c
APEX_ROUTE_DECLINED
APEX_ROUTE_STATIC
APEX_ROUTE_APPLICATION
```

No live request reparses the manifest or infers native routes from `.php` file
extensions.

### Runtime manager

The runtime manager owns process-level PHP startup, lazy thread attachment,
native application boot, compatibility execution, poison state, and orderly
shutdown. Its external interface hides TSRM and SAPI ordering:

```c
apex_runtime_result apex_runtime_execute(
    apex_runtime_manager *manager,
    const apex_request *request,
    apex_response_sink *response
);
```

### Request bridge

The request bridge builds an immutable Apex request containing the method,
scheme, authority, path, query, headers, cookies, client identity, authenticated
Apache user, body stream, deadline, and cancellation state. It never exposes
`request_rec` to userland.

### Application host

The application host loads the single application bootstrap and retains the
resulting native application object for the lifetime of the thread runtime. It
owns the persistent service registry and creates a new request scope for every
logical request.

### Response bridge

The response bridge validates status, headers, cookies, fixed bodies, and
streams. It owns the transition from uncommitted to committed output and
prevents status or header mutation after the first body chunk.

### Lifecycle guard

The lifecycle guard records completed stages and unwinds them in reverse order.
Scattered cleanup branches must not directly manage PHP request state.

### Metrics

Metrics use thread-local counters on the request path and merge outside the hot
path. Formatting occurs only when a metrics endpoint is requested.

## Native Runtime Lifecycle

The native runtime uses one real PHP request to host many Apex logical requests.
This is required because ordinary PHP userland objects do not survive
`php_request_shutdown()`.

### First Apex request on a thread

1. Attach the thread's TSRM state.
2. Run `php_request_startup()` once.
3. Load the application bootstrap.
4. Construct the persistent application and service registry.
5. Mark the runtime ready.

### Every logical HTTP request

1. Open a new Apex request scope.
2. Build the immutable request.
3. Reset transient Apex-managed PHP state.
4. Call the application handler.
5. Validate and commit the response.
6. Run registered after-request cleanup.
7. Destroy the request scope.
8. Decide whether the runtime is safe to reuse.

### Apache child shutdown

1. Stop accepting new application work.
2. Allow active requests to drain within the configured deadline.
3. Shut down persistent services in reverse registration order.
4. Destroy the application object.
5. Run `php_request_shutdown()` for each initialized thread runtime.
6. Shut down the child process's embedded PHP engine.

The implementation must not call PHP thread-owned shutdown operations from a
different thread. Apache child cleanup coordinates shutdown, while each worker
runtime performs its own thread-affine teardown before exit. If orderly
thread-affine teardown is unavailable, process exit is the final isolation
mechanism and the design must not pretend cross-thread cleanup is safe.

## Compatibility Lifecycle

Compatibility mode uses traditional PHP request semantics:

1. Attach thread state.
2. Run `php_request_startup()`.
3. Populate superglobals and SAPI request information from the internal request.
4. Execute the configured front controller.
5. Capture status, headers, cookies, and output as an internal response.
6. Run `php_request_shutdown()`.
7. Clear all SAPI request pointers before returning to Apache.

Compatibility mode shares manifest routing, request limits, cancellation,
response validation, logging, and metrics with native mode. It does not promise
persistent userland application objects.

## Persistence Rules

Native persistence is explicit. Objects created during bootstrap or registered
as persistent services may survive logical requests. Objects resolved through
the request scope must not survive the scope.

Conceptual registration:

```php
return Apex::application()
    ->persistent(DatabasePool::class, $databaseFactory)
    ->persistent(CacheClient::class, $cacheFactory)
    ->handler(AppHandler::class);
```

Persistent services that retain request-adjacent resources implement lifecycle
hooks:

```php
interface ApexPersistentService
{
    public function beforeRequest(ApexRequest $request): void;
    public function afterRequest(ApexRequestOutcome $outcome): void;
    public function shutdown(): void;
}
```

The database adapter rolls back an unfinished transaction after every request.
Authentication and session adapters clear current-user state. The response
bridge discards uncommitted buffers. Failure of a required cleanup hook poisons
the runtime.

Native applications must not use mutable superglobals as their request
interface. The compatibility adapter may populate them because that mode uses a
real PHP shutdown after each request.

## Application Interface

The core userland interface is intentionally small:

```php
interface ApexApplication
{
    public function handle(ApexRequest $request): ApexResponse;
}
```

`ApexRequest` is immutable and exposes method, scheme, authority, path, query,
headers, cookies, body, client information, cancellation, and request scope.
Query and cookie parsing are lazy and cached only within the logical request.

`ApexResponse` is an immutable response builder with fixed-body and streaming
forms. It validates:

- HTTP status range
- Header names and values
- Multi-value header behavior, including `Set-Cookie`
- Bodyless status rules
- `Content-Length` agreement for fixed bodies
- Ownership of hop-by-hop headers by Apache

## Body and Response Streaming

Request bodies are streamed rather than unconditionally buffered. Reads honor
Apache timeouts, client disconnects, configured size limits, and cancellation.

Response streams write through an Apex-controlled sink. The sink:

- Respects Apache output-filter backpressure
- Stops after cancellation or client disconnect
- Commits headers on the first non-empty body write
- Rejects header and status mutation after commitment
- Records whether a partial response reached the client

An exception before commitment may produce the configured generic error
response. An exception after commitment closes the stream, records the partial
response, runs cleanup, and poisons the runtime when safe reuse cannot be
proven.

## Manifest

Apache points Apex to one application manifest:

```apache
ApexApplication /var/www/myapp/apex.toml
```

Example:

```toml
[application]
name = "storefront"
root = "/var/www/myapp"
bootstrap = "bootstrap.php"
mode = "native"

[routes]
dynamic = ["/", "/api/*", "/account/*"]
static = ["/assets/*", "/favicon.ico", "/robots.txt"]

[runtime]
max_requests = 10000
max_age = "30m"
process_memory_recycle = "768M"
request_timeout = "30s"
max_body = "32M"
max_concurrent_streams = 16

[health]
live = "/.apex/live"
ready = "/.apex/ready"
```

`application.mode` is the single mode selector and accepts `native` or
`compatibility`. Native mode requires `bootstrap`; compatibility mode requires
`compatibility.front_controller`. Supplying keys for the inactive mode is a
configuration error rather than an ignored setting.

`runtime.max_requests`, `runtime.max_age`, and
`runtime.process_memory_recycle` apply to the Apache child as a whole and
request graceful child recycling. They are not per-thread PHP memory limits.

The manifest parser rejects unknown keys, invalid values, overlapping routes,
missing files, paths outside the application root, and unsafe static-route
traversal. It resolves paths to canonical absolute paths and compiles routes
before Apache forks.

Application source stays outside the public static directory. A graceful reload
validates and boots a new immutable application generation before old children
drain. Production code is never reloaded inside a live runtime.

## Failure Containment

Normal application exceptions become controlled responses and run ordinary
cleanup. Cancellation and deadlines request cooperative unwinding.

The runtime is poisoned when any of the following occurs:

- PHP fatal error or bailout with uncertain state
- Application bootstrap failure after partial initialization
- Required cleanup failure
- Open transaction that cannot be rolled back
- Corrupted or leaked request scope
- Timeout that cannot unwind safely
- Response-bridge invariant violation

A poisoned child stops accepting new Apex work, drains safe active requests,
and exits. Apache creates a clean replacement. The architecture prefers losing
one child over reusing state that might expose one request to another.

Proactive child recycling uses maximum request count, maximum age, and sampled
process memory. Container memory limits remain the firm external boundary.

## Health, Metrics, and Logging

Static liveness does not invoke PHP. Readiness reflects validated configuration,
successful PHP initialization, and application-generation health.

Metrics include request counts, status classes, cancellations, timeouts,
active requests, runtime boots and failures, poisoned runtimes, child recycle
reasons, body bytes, response bytes, handler duration, and cleanup duration.

Request logs include request ID, application generation, child PID, thread ID,
route, status, duration, bytes, response-commit state, cleanup result, and
recycle reason. Headers, cookies, query values, request bodies, and secrets are
not logged by default.

## Source Layout

```text
include/
  apex_manifest.h
  apex_routes.h
  apex_runtime.h
  apex_request.h
  apex_response.h
  apex_lifecycle.h
  apex_metrics.h
src/
  mod_apex.c
  apache_adapter.c
  manifest.c
  route_matcher.c
  runtime_manager.c
  application_host.c
  php_native_interface.c
  request_bridge.c
  response_bridge.c
  body_stream.c
  compatibility_adapter.c
  lifecycle_guard.c
  metrics.c
tests/
  unit/
  integration/
  failure/
  load/
examples/
  hello-native/
  legacy-front-controller/
```

## Verification Strategy

### Unit tests

Test manifest validation, route matching, traversal rejection, headers, cookies,
response commitment, lifecycle transitions, cancellation, and metrics without
starting Apache or PHP.

### PHP integration tests

For every supported PHP ZTS release, verify process startup, lazy thread
runtime boot, explicit persistence, request-scope destruction, compatibility
startup/shutdown balance, OPcache, cleanup hooks, and poison behavior.

### Apache integration tests

Use disposable real Apache instances to verify static bypass, dynamic routing,
streaming bodies, headers, cookies, disconnects, graceful reloads, child
replacement, invalid configuration rejection, HTTP/1.1, and HTTP/2.

### Failure injection

Inject failure at thread attach, PHP startup, bootstrap, request construction,
body read, handler call, header commit, body write, cleanup, and shutdown. Each
case must prove correct client behavior where possible, no unsafe reuse, no
post-shutdown context access, and continued Apache availability.

### Memory and concurrency checks

Run sanitizers where dependencies permit, bounded Valgrind cases, repeated
reloads, disconnect storms, slow uploads, slow readers, sustained native and
compatibility traffic, and process-memory slope checks.

### Performance gates

After correctness passes, compare static bypass overhead, native and
compatibility throughput, p50/p95/p99 latency, memory per active runtime,
application boot time, streaming behavior, and disconnect behavior against the
previous release on the same host. Benchmark results do not waive correctness
or isolation requirements.

## Non-Goals

- Hosting multiple dynamic applications in one Apache instance
- Running untrusted tenants inside one child process
- Replacing Apache's TLS, authentication, proxy-trust, or static-file features
- Automatic in-place production code reload
- Transparent persistence for arbitrary legacy PHP globals
- Cross-thread sharing of PHP userland objects
- A separate Apex daemon or FastCGI-compatible worker pool

## Implementation Constraints

- Preserve thread affinity for PHP and TSRM state.
- Never access request context after its owning lifecycle stage has ended.
- Never reuse a runtime after uncertain cleanup.
- Keep native and compatibility lifecycles explicit and separately testable.
- Do not add proxy-header trust decisions inside Apex.
- Validate configuration before serving a new generation.
- Keep the application-facing interface independent of Apache and SAPI types.

## Success Criteria

The architecture succeeds when:

- Native requests execute without an inter-process handoff.
- Static requests incur only route-selection overhead.
- Persistent services survive logical requests only when explicitly registered.
- Request identity, body, output, transactions, and scoped objects never leak
  between logical requests.
- Compatibility mode preserves a balanced real PHP request lifecycle.
- Fatal or uncertain runtime state is contained to a replaceable Apache child.
- A failed new generation cannot replace a healthy serving generation.
- Operators can identify health, cleanup failures, and recycle reasons without
  enabling verbose per-request tracing.
