# T22 — Compose parsing, interpolation and the service graph

**Milestone:** M6 · **Depends on:** T21 · **Status:** done

Pure code, no daemon, no UI. Turns a `compose.yaml` into a validated project spec plus a list of
diagnostics, and works out what order the services start in.

## Upstream references
None — compose is entirely ours. The only external API is Yams.

## Design notes
- Parse with `Yams.compose(yaml:)` into a `Node` tree and walk it by hand. Decoding straight into
  `Codable` structs throws away `Node.Mark`, and a `DecodingError` on a 200-line compose file is
  unreadable. Every diagnostic carries a dotted path and a line.
- **Unknown keys are warnings, not errors.** The compose spec keeps growing; a hard failure would
  make the app useless on files that would otherwise run perfectly.
- Interpolation is not optional — nearly every real file uses it. `.env` sits below the process
  environment, per the compose spec.
- `env_file` is read here rather than passed through to `RunSpec.environmentFiles`, because
  `Flags.Process.envFile` resolves relative paths against *Dockyard's* working directory, not the
  compose file's. Reading it ourselves also brings those values inside T23's hostname rewriting,
  which they would otherwise escape entirely.

## Files
- `Compose/ComposeDiagnostic.swift`
- `Compose/ComposeFile.swift` — `ComposeProjectSpec`, `ComposeService`, `ComposeMount`,
  `ComposeRestartPolicy`, `ComposePortMapping`
- `Compose/ComposeInterpolation.swift`
- `Compose/ComposeParser.swift` — pure `Node` → spec + diagnostics
- `Compose/ComposeLoader.swift` — the only part that touches the filesystem
- `Compose/ComposeGraph.swift`

## Acceptance
- [x] Both `environment` forms and both `depends_on` forms parse; a bare `DEBUG` becomes `DEBUG=`.
- [x] Interpolation covers `$VAR`, `${VAR}`, `${VAR:-d}`, `${VAR-d}`, `${VAR:?msg}`, `${VAR?msg}`,
      `$$`, with `.env` below the process environment. `:?` collects **every** missing variable and
      names each one, rather than stopping at the first.
- [x] An unknown key is a warning and the file still loads; `x-` keys are not even warned about.
- [x] `healthcheck`, `networks`, `container_name`, `profiles`, `deploy` each produce their own named
      `ignored` diagnostic, table-driven so a new one cannot be added without a test.
- [x] Malformed YAML and a service with no `image:` both fail as errors; a service with `build:` says
      so rather than complaining about a missing image.
- [x] Start order is topological, and asserted identical across 50 runs of the same input.
- [x] A cycle is refused naming **only its own members** — a downstream service that merely depends on
      the cycle is not dragged into the message. Self-dependency is caught too.
- [x] A `depends_on` on an undefined service names both.
- [x] **A realistic file parses end to end**: a three-service stack with `.env`, a password
      interpolated inside a connection URL, a read-only bind mount, `depends_on` with conditions, a
      healthcheck and a declared volume — no blocking diagnostics, correct start order, and the two
      unsupported keys named.
- [x] 382 unit tests in 53 suites; `xcodebuild` clean.

## Findings

- **`$` before a letter is a variable reference even inside a password hash**, so `$2y$10$abcdef`
  loses its tail. That is compose's own behaviour — it is why Docker tells you to write `$$` — and it
  is pinned by a test so nobody later "fixes" it into a divergence from every other compose tool.
- **`depends_on` is sorted in both syntaxes.** The list form originally preserved file order while the
  mapping form sorted, which meant two files differing only in the order they listed dependencies
  produced different specs. That would change the config hash in T24 and recreate containers over a
  cosmetic edit.
- `FileManager` is not `Sendable`, so `ComposeLoader` uses `.default` directly rather than storing an
  injected one. The tests use real temporary files instead, which is the more faithful arrangement
  anyway — path resolution is the thing most likely to be wrong and a stubbed filesystem would not
  catch it.
- Kahn's algorithm stalls on a cycle but cannot say which services form it, and "there is a cycle
  somewhere" is not a fixable message. A DFS over the unplaced nodes recovers one real loop, trimming
  the prefix that merely led into it.

## Notes
