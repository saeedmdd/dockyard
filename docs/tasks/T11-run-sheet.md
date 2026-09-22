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
- [ ] Run `nginx` with port `8080:80` → container running; `curl localhost:8080` returns nginx page.
- [ ] Env, mount (`~/tmp:/data`), cpus 2, memory 512M all visible in Inspect and in `container inspect`.
- [ ] Image not present locally → sheet shows pull progress then creates.
- [ ] Invalid name (spaces) → inline validation error, no request sent.
- [ ] "Create" only → container appears `.stopped`; Start from T05 works.
- [ ] Unit tests green.

## Notes
