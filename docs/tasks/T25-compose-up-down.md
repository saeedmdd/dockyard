# T25 — `up` and `down`

**Milestone:** M6 · **Depends on:** T24 · **Status:** done

The first compose task that touches the daemon. Reconciles a plan against what is already running,
and tears a project down again.

## Design notes
- **Serial, in start order.** Image pulls dominate, the runtime serialises creates anyway, and serial
  execution makes progress reporting and cancellation trivially correct. Parallel waves are a later
  optimisation, not a design requirement.
- **Reconciliation, not recreation.** Existing + hash matches + running → reuse; hash matches +
  stopped → start; hash differs → recreate; missing → create. A second `up` with no edits must
  create nothing.
- **Partial failure stops and leaves what is up running.** Tearing down a database the user has just
  seeded because a later service had a typo is strictly worse than a half-started project. The UI
  offers Retry — which is idempotent — and Down.
- **`down` takes its container set from the label filter, not the file**, so a service deleted from
  the compose file is still torn down, and a project whose file has moved can still be stopped. Its
  order comes from the `depends-on` label for the same reason.
- `Task.checkCancellation()` before every `.ready` and before declaring success: a cancelled
  `AsyncThrowingStream` *finishes* rather than throws, which has already bitten `BuildStore` and
  `RunStore`.

## Files
- `Compose/ComposeProject.swift` — what a project looks like once discovered from labels
- `Stores/ComposeStore.swift` — `ComposeJob`, `ComposeStore`

## Acceptance
- [x] `up` creates in dependency order and starts each after creating it, asserted on the recorded
      invocation order, not just on the final state.
- [x] A second `up` with no changes creates nothing, starts nothing, and marks every step reused.
- [x] A changed setting recreates only that service; the untouched one is reused.
- [x] A failure partway names the failing service, leaves the earlier one running, and **rolls
      nothing back**.
- [x] Cancellation reports `.cancelled`, never success.
- [x] A port held by another container is refused before any create, naming both the port and the
      container holding it.
- [x] `down` works from labels with no file involved, in reverse dependency order taken from the
      `depends-on` label, and touches nothing outside the project.
- [x] Projects are discovered from labels alone.
- [x] **Integration, against the real daemon**: up, then down leaving nothing; a second up where the
      containers' `createdAt` is unchanged, so they are the same containers rather than replacements
      that look alike; a changed service recreated while its neighbour is not; `down` after the
      compose file has been deleted; and a bystander container untouched by either.
- [x] 441 unit tests in 61 suites, 65 integration tests run twice with zero leftovers; `xcodebuild`
      clean.

## Findings

- **The mock was creating containers under a synthetic id.** It returned `created-1` regardless of
  the spec's name, so every follow-up — start, the labels, a second `up`'s reconciliation — addressed
  something that did not exist under the name the caller asked for. It honours `spec.name` now and
  records the invocation, which is what makes the ordering and reuse assertions meaningful.
- **`withFixture` could not carry an actor-isolated body.** Stores are `@MainActor`, and a closure
  handed to the plain `withFixture` arrives without isolation, so every call inside it was a
  cross-actor hop the compiler refused. Adding `sending` fixed the compose suites and broke
  `VolumeIntegrationTests`; a separate `withMainActorFixture` keeps both readable.
- **`InspectParityTests` held a latent race that these tests exposed.** It inspected whatever
  `listContainers().first` returned, and another suite deleting that container between the list and
  the CLI call left a truncated document that failed to parse. Harmless while it was the only suite
  creating containers; not once projects come and go beside it. It owns its container now.

## Notes
