# T13 — Build sheet via `container build`

**Milestone:** M3 · **Depends on:** T10 · **Status:** todo

## Goal
Build an image from a Dockerfile/Containerfile with streamed output and cancellation. v1 runs the CLI
(the build pipeline is CLI-only upstream); the sheet/store API is designed so T-future can swap in the
`ContainerBuild` gRPC pipeline without UI changes.

## Upstream references
- `Sources/ContainerCommands/BuildCommand.swift` — flags: `-t/--tag`, `-f/--file`, `--platform`, `--build-arg`, `--no-cache`, `--progress`, `--cpus`, `--memory`, `--target`, `--label`, `-o/--output`; builder auto-start behaviour (`BuilderStart.start` + wait loop).
- `Sources/ContainerCommands/Builder/BuilderStart.swift`, `BuilderStatus.swift`, `BuilderStop.swift`.

## Files
- `Models/BuildSpec.swift` — `contextURL, dockerfile (relative path), tag, platform?, buildArgs: [String:String], noCache, target?, labels`. `func cliArguments() -> [String]` (unit-tested).
- `Backend/CLIRunner.swift` — `build(_ spec: BuildSpec) -> AsyncThrowingStream<CLIEvent, Error>`; pass `--progress plain` so output is line-based; `cwd = contextURL`.
- `Stores/BuildStore.swift` — `jobs: [BuildJob]` (spec, lines, state .running/.succeeded/.failed(code), task); `start(spec:)`, `cancel(_:)`; on success `imageStore.refresh()`.
- `Dockyard/Images/BuildSheet.swift` — folder chooser (NSOpenPanel, `canChooseDirectories`) + drop target; Dockerfile picker auto-selects `Dockerfile` then `Containerfile` if present; tag (required, validated `name[:tag]`); platform; build-args KV editor; no-cache toggle; target field.
- `Dockyard/Images/BuildJobView.swift` — reuses `LogTextView` for output, Cancel/Close, elapsed time; jobs listed in Images sidebar section "Builds".
- `Tests/DockyardCoreTests/BuildSpecTests.swift`.

## Acceptance
- [x] Sheet works end to end up to the build itself: chose a folder, the Dockerfile was detected
      automatically, and the tag was suggested from the folder name (`t13ctx:latest`).
- [x] A failing build surfaces properly in the UI — the job row read **"Failed with exit code 1 —
      Error: internalError: "failed to bootstrap container" …"** — with the real runtime error rather
      than a swallowed failure.
- [x] Cancellation verified against a real `container build`: the process is killed and no tagged
      image is left behind.
- [x] `--progress plain` is asserted in the command, and checked for ANSI escapes when a build can
      complete.
- [x] 204 unit tests in 31 suites; 28 integration tests; `xcodebuild` clean.
- [x] **A successful build now works** — see the resolution below.
- [ ] ~~A successful build could not be verified on this machine~~ — see below. The tests that need
      one are gated and skip cleanly; they will run wherever the builder works.

## Resolved: it was the runtime, and 1.4.1 fixes it

The builder is itself a multi-layer image, and on `container` 1.0.0 **no** multi-layer image could
be mounted on this machine: one layer started, three and eight failed with the same
`internalError: "mount"`. Nothing to do with the builder specifically.

Upgrading to 1.4.1 fixes it, with one catch worth knowing: an image unpacked by the old runtime
keeps a snapshot the new one still cannot mount, so the image has to be re-pulled or rebuilt before
it will start. A freshly pulled multi-layer image works immediately.

`container build` now completes, the built image runs, and `CompletedBuildTests` — the suite that
had been skipping itself via `BuilderProbe` — runs and passes. Gating that suite on a probe rather
than hard-disabling it is what let it switch itself back on with no edit.

## What it looked like at the time (kept for the record)
`container build` fails before reaching the Dockerfile:

```
Error: internalError: "failed to bootstrap container"
  (cause: "failed to bootstrap container buildkit (cause: "unknown: "internalError: "mount"""))
```

This is **not** Dockyard. Established by:
- `container build` run directly from the terminal fails identically.
- `container builder start` fails identically on its own.
- Re-pulling `ghcr.io/apple/container-builder-shim/builder:0.12.0` did not help.
- The builder's virtiofs export directory exists, so the mount source is present.
- Ordinary containers start and run fine (nginx with a published port worked in T11), so the
  runtime itself is healthy — it is specifically the builder container.

It is the same class of failure as the stale-snapshot problem in T04, where images pulled by an
older `container` release could not be mounted by the current one.

**Note on the container count:** it went from 7 to 6 during this task. The missing one is
`buildkit`, the runtime's own builder container, which the *runtime* deleted when its bootstrap
failed — visible in the system log as `ContainersService … [id=buildkit] … delete(id:force:)`. It is
recreated automatically whenever the builder next starts. All six user containers are untouched.

## Findings
- `--progress plain` is mandatory, not a preference: the default (`auto`) emits a redrawing TTY
  display, which piped into a text view is a screenful of escape sequences.
- The builder-usable probe cannot be `container builder status` — that exits 0 and reports "builder
  is not running" even when starting one is impossible. Only attempting a start answers the
  question, so `BuilderProbe` does that once, synchronously, to gate a suite.
- Tests that hold regardless of the builder (failure reporting, cancellation) are kept in a suite
  that always runs, so a broken builder does not silently remove coverage of the parts that work.
- The sheet suggests an image name from the folder, because an untagged build is filed under a
  generated UUID and is effectively lost.
- Dropping a Dockerfile rather than its folder is an easy mistake, so a dropped file resolves to its
  containing directory.

## Notes
