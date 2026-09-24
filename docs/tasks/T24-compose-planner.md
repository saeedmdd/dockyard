# T24 — The planner: compose spec → runnable container specs

**Milestone:** M6 · **Depends on:** T23 · **Status:** done

Pure code. Turns a parsed project into the `RunSpec`s `up` will create, plus the digest that decides
whether an existing container is already correct.

`up`/`down` orchestration is T25; this is everything that can be decided without touching the daemon.

## Design notes
- **Naming**: `<project>-<service>`, validated with `EntityName`. The project name is sanitised on the
  way in, and the resulting FQDN is length-checked — it becomes a DNS label, and a long folder name
  plus a long service name silently produces something unresolvable.
- **`networks` is always empty.** An empty list makes the runtime attach the built-in `default`
  network, which is the only one where containers resolve each other by name. The compose file's own
  `networks:` is deliberately ignored (T22 reports it).
- **`removeWhenStopped` is always false.** A container that deletes itself breaks `down`, status
  tracking and the supervisor.
- **`startImmediately` is false**: `up` starts explicitly, so a create failure and a start failure are
  attributable to different steps.
- **The config hash must not be a `JSONEncoder` of the `RunSpec`.** `RunSpec.KeyValue.id` is a fresh
  `UUID` and is `Codable`, so encoding the spec yields a different digest every run — and every `up`
  would delete and recreate every container, losing container-local state. A canonical projection,
  with a stability test.

## Files
- `Compose/ComposePlanner.swift` — `ComposeServicePlan`, `ComposeUpPlan`, `plan(_:dnsDomain:)`

## Acceptance
- [x] `networks` is empty on every spec, **including when the file asks for one**, and
      `removeWhenStopped` and `startImmediately` are false.
- [x] Container names are `<project>-<service>` and pass `EntityName`.
- [x] **The config hash is stable across two independent plans of the same file**, and changes for
      each of image, environment, ports, volumes, command and restart — table-driven.
- [x] **The trap is proven, not just avoided**: a test asserts that encoding the two `RunSpec`s
      *would* differ, and says so, so if `KeyValue.id` ever stops being a `UUID` the canonical
      projection can be simplified deliberately rather than by accident.
- [x] Reordering a file without changing its meaning keeps the hash, so a cosmetic edit does not
      recreate containers.
- [x] Named volumes are prefixed `<project>_<name>` and listed as owned; a declared `external: true`
      volume keeps its name and is **not** owned, so `down` can never remove someone else's data.
- [x] Relative bind sources are absolutised against the compose file's directory.
- [x] Rewriting is applied and recorded, and skipped for a service with `x-dockyard.rewrite: false`.
- [x] With no DNS domain, nothing is rewritten and a diagnostic says containers cannot reach each
      other by name.
- [x] An over-long name is refused with the 63-character limit named.
- [x] Steps come back in dependency order, stop order is the reverse, and a cycle refuses the plan.
- [x] 427 unit tests in 58 suites; `xcodebuild` clean.

## Findings

- The config-hash trap was real and is now pinned from both sides: one test asserts the hash is
  stable, another asserts that the naive `JSONEncoder` approach would **not** have been. The second
  is the one that will still be useful in a year — it documents why the canonical projection exists,
  so nobody deletes it as redundant.
- `restart:` is in the hash even though it does not change the container's runtime behaviour, because
  it is written into a label and labels cannot be updated without recreating. Leaving it out would
  let the label go stale and the supervisor act on a policy the file no longer asks for.
- Labels are excluded from the hash for the obvious reason that one of them *is* the hash.
- The planner never touches the daemon, so all of this is unit-testable. Nothing here needed an
  integration test, which is the point of keeping `up` in its own task.

## Notes
