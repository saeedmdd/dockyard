# T11 — Full Run sheet

**Milestone:** M2 · **Depends on:** T05, T10 · **Status:** todo

## Goal
Create (and optionally start) a container from an image with every `container run` option, reusing
the CLI's own flag→configuration translation so validation matches exactly.

## Upstream references
- `Sources/Services/ContainerAPIService/Client/Utility.swift` — `containerConfigFromFlags(id:image:arguments:process:management:resource:registry:imageFetch:containerSystemConfig:progressUpdate:log:) -> (ContainerConfiguration, Kernel, String?)`, `createContainerID(name:)`, `validEntityName`, `parseKeyValuePairs`.
- `Sources/Services/ContainerAPIService/Client/Flags.swift` — `Flags.Process` (env, envFile, uid, gid, user, cwd, ulimits), `Flags.Management` (arch, capAdd/Drop, dns, entrypoint, initImage, kernel, labels, mounts, name, networks, publishPorts, publishSockets, platform, runtime, shmSize, tmpFs, virtualization, volumes, …), `Flags.Resource` (cpus, memory), `Flags.DNS`, `Flags.Registry`, `Flags.ImageFetch`. All `ParsableArguments` → construct with `init()` then set vars.
- `Sources/ContainerCommands/Container/ContainerRun.swift` / `ContainerCreate.swift` — the sequence: id → validate → `containerConfigFromFlags` (pulls image if missing, with progress) → `client.create(configuration:kernel:options:)` → (run) bootstrap+start as in T05.
- `ContainerConfiguration.swift` — `initProcess.terminal`, `interactive` flags.

## Files
- `Models/RunSpec.swift` — plain struct mirroring all fields above, `Codable` (for "recent runs" and presets). `func toFlags() -> (Flags.Process, Flags.Management, Flags.Resource, Flags.Registry, Flags.ImageFetch)` lives in `Backend/RunSpec+Flags.swift` (only place importing upstream).
- `Backend/ContainerBackend.swift` — `createContainer(spec: RunSpec, progress:) -> String id`, `runContainer(spec:)`.
- `Stores/ContainerStore.swift` — `run(spec:)`, `create(spec:)`; image-pull progress surfaces via the same `PullProgress` model.
- `Dockyard/Containers/RunSheet/RunSheet.swift` — sections (collapsible `DisclosureGroup`s): Basic (name auto = `Utility.createContainerID`, image picker from ImageStore or free text, command args, entrypoint, workdir, user/uid/gid, TTY, interactive), Ports (host:container list editor), Env (KV editor + env-file picker), Storage (mounts, volumes, tmpfs), Resources (cpus stepper, memory field), Network (networks multi-select, hostname, DNS nameservers/domain/search/options), Advanced (platform/arch, kernel, cap add/drop, labels, shm size, virtualization, publish sockets). "Create" and "Create & Start" buttons.
- `Dockyard/Components/KeyValueListEditor.swift`, `StringListEditor.swift`, `PortMappingEditor.swift`.
- `Tests/DockyardCoreTests/RunSpecFlagsTests.swift` — every field round-trips into the right `Flags` var; invalid names rejected by `validEntityName`.

## Acceptance
- [x] Ran `nginx:alpine` with `18080:80` from the sheet. `container inspect` shows exactly
      `hostPort: 18080 → containerPort: 80/tcp`, and **`curl http://127.0.0.1:18080` returns HTTP 200
      with "Welcome to nginx!"**. A CLI-created container on 18081 behaves identically, so the app's
      publishing is the runtime's, not an approximation of it.
- [x] Image not present locally → the sheet showed "Fetching image · 6.2 MB…" and then created the
      container. `containerConfigFromFlags` does the fetch, so this path is the same one `container
      run` takes for a missing image.
- [x] "Start immediately" produced running containers, confirmed by `container list`.
- [x] Validation refuses an empty image ("Choose an image to run.") and bad names/ports before
      anything is sent.
- [x] 183 unit tests in 29 suites, 8 integration tests; `xcodebuild` clean.

## Findings
- **ArgumentParser's property wrappers trap when read after a plain `init()`.** `Flags.Management()`
  compiles and then dies at the first read with *"Can't read a value from a parsable argument
  definition"* — the wrappers only populate their storage during parsing. The flags are therefore
  built with `try Flags.X.parse([])`, which applies every declared default (host architecture,
  `linux`, scheme `auto`, three concurrent downloads). That is also the point: those defaults are
  inherited from the CLI rather than restated here, so they cannot drift.
- Going through `Flags` → `containerConfigFromFlags` rather than building a `ContainerConfiguration`
  directly means the runtime applies exactly the validation it applies to `container run`, including
  fetching and unpacking a missing image and resolving the kernel.
- Command text is split honouring quotes, so `sh -c "echo hello world"` arrives as three arguments.
  Splitting on whitespace would break nearly every non-trivial command typed into the sheet.
- Blank optional fields become `nil`, not `""` — an empty string would read as a deliberate choice.
- The sheet keeps only image, name, command and two toggles in front; the other ~30 options live in
  six collapsible sections, each showing a small summary when collapsed so nothing configured is
  invisible.

## Test-harness note (not an app defect)
Setting a SwiftUI `TextField`'s AX value without focusing it first does not commit its binding, so
scripted runs produced containers with generated UUID names instead of the name typed into the
field. The image field, which was focused first, committed correctly. Worth remembering when driving
this sheet from a script.

## Notes
