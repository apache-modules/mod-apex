# Aero Runtime Delivery Roadmap

The Aero Runtime for Apache architecture is delivered through separate plans.
Each stage must leave independently testable software and must not destabilize
the released `mod_apex` module.

Aero lives in the standalone `/home/bode/sites/mod_aero` Git repository. The
`/home/bode/sites/mod_apex` repository is a read-only migration reference and
retains its own releases and history.

## Naming and coexistence

- Product: Aero Runtime for Apache
- Apache module: `mod_aero`
- Module symbol: `aero_module`
- Manifest: `aero.toml`
- Apache directive: `AeroApplication`
- PHP namespace: `Aero`
- Existing `mod_apex` packages, image, configuration, and documentation remain
  unchanged until the final cutover plan is approved.

## Plan sequence

1. **Foundation and routing**
   - Bootstrap the standalone `mod_aero` repository.
   - Vendor a pinned TOML parser.
   - Implement strict manifest validation and immutable route decisions.
   - Build a non-claiming `mod_aero` shell that validates `AeroApplication`
     during `apachectl -t` and always returns `DECLINED` at runtime.

2. **Compatibility execution**
   - Extract the proven request/response translation behavior from
     `mod_apex.c` behind Aero interfaces.
   - Implement compatibility mode with balanced PHP startup/shutdown per HTTP
     request.
   - Validate parity before any native persistent lifecycle is introduced.

3. **Native runtime and PHP interface**
   - Add per-child PHP ownership and lazy per-thread native runtimes.
   - Register the immutable `AeroRequest`, `AeroResponse`, application, service,
     and request-scope interfaces.
   - Boot one native application per initialized Apache worker thread.

4. **Streaming and failure containment**
   - Add request-body streaming, response backpressure, cancellation, deadlines,
     lifecycle guards, poison state, and graceful child recycle behavior.

5. **Operations and generations**
   - Add liveness, readiness, metrics, structured diagnostics, resource
     thresholds, immutable generations, and safe graceful reload behavior.

6. **Packaging and cutover**
   - Build parallel Aero packages and image tags.
   - Publish migration tooling and compatibility guidance.
   - Run ABI, integration, failure, memory, and performance release gates.
   - Rename public distribution artifacts only after Aero passes those gates.

## Release rule

No plan may delete, rename, disable, or silently redirect the current
`mod_apex` implementation. Aero remains an opt-in parallel module until the
packaging-and-cutover plan explicitly changes that rule.
