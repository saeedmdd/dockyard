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
- [ ] Tag `alpine:3.20` → `myalpine:dev` appears; `container image list` agrees.
- [ ] Delete unused image → gone. Delete image used by a container → blocked with names listed.
- [ ] Inspect shows config JSON matching `container image inspect`.
- [ ] Infra images hidden by default, shown with toggle.

## Notes
