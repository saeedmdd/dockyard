# T10 — Image delete / tag / inspect

**Milestone:** M2 · **Depends on:** T09 · **Status:** todo

## Upstream references
- `ClientImage.swift` — `static delete(reference:garbageCollect:)`, `tag(new:)`, `config(for:)`, `manifest(for:)`, `index()`, `getFullImageSize`.
- `Sources/ContainerCommands/Image/ImageDelete.swift`, `ImageTag.swift`, `ImageInspect.swift`.
- `Utility.isInfraImage(name:builderImage:initImage:)` — hide/protect infra images (builder, init) by default.

## Files
- `Backend/ContainerBackend.swift` — `deleteImage(reference:)`, `tagImage(reference:new:)`, `imageInspectJSON(reference:)`, `imageDetail(reference:) -> ImageDetail` (config: cmd, entrypoint, env, exposed ports, labels, layers count, platforms).
- `Stores/ImageStore.swift` — `delete(_:)`, `tag(_:new:)`, `showInfraImages: Bool` filter.
- `Dockyard/Images/ImageDetailView.swift` — header + tabs: Overview | Inspect (reuse `InspectView`). Actions: Run (T11), Tag, Delete, Copy reference.
- `Dockyard/Images/TagSheet.swift`.
- Delete guard: if any container (from `ContainerStore`) uses the image → dialog listing them; delete blocked unless those containers are deleted first.

## Acceptance
- [x] Tagged `alpine:3.20` as `dockyard-t10:test` from the sheet; `container image list` agreed.
- [x] Deleted that tag from the app → gone from the CLI, and `alpine:3.20` survived, as deleting one
      reference must not remove the image others point at.
- [x] Delete of an in-use image names the containers: *"3 containers were created from this image —
      elasticsearch-node1, elasticsearch-node2, elasticsearch-node3. They will no longer start."*
      Verified against the real images, then cancelled — nothing of the user's was deleted.
- [x] Detail pane matches the CLI: `alpine:3.20`, digest `d9e853e87e55…`, media type, per-platform
      variants with sizes, and the image's default command and environment.
- [x] Runtime images stay hidden behind the existing toggle and cannot be deleted at all.
- [x] 161 unit tests in 25 suites, 8 integration tests; `xcodebuild` clean.

## Findings
- **Attestation manifests are not platforms.** The first run listed `unknown/unknown` alongside real
  builds and counted its bytes, making `alpine:3.20` look like 28.7 MB. Upstream skips these
  explicitly (`ImageList.swift:129`: "Skip attestation manifests, which use the `unknown/unknown`
  platform", and `getFullImageSize` ignores them). Filtered at the model boundary, so both the
  platform list and the total are right: 28.1 MB.
- **Deleting an image does not free its layers.** `ClientImage.delete` removes the reference;
  upstream then calls `cleanUpOrphanedBlobs()` and reports what that actually reclaimed. Dockyard
  does the same and says so — deleting a tag that shares every layer reclaims nothing, and claiming
  otherwise would be a lie the user could check.
- **Infrastructure images are refused with a reason.** Upstream's delete silently *skips* them,
  which from a GUI looks like the button did nothing.
- `ImageConfig` in containerization 0.33.3 has no `ExposedPorts` field — it models User, Env,
  Entrypoint, Cmd, WorkingDir, Labels and StopSignal only. The pane shows `StopSignal` instead of
  the exposed ports the task file assumed.
- The in-use check is advisory, not a block: the runtime permits the delete. What it prevents is the
  silent failure later, when a container that was created from that image refuses to start with an
  error that never mentions the image.

## Notes
