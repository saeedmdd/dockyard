# T17 — Registry login, push, save

**Milestone:** M4 · **Depends on:** T10 · **Status:** todo

## Upstream references
- `Sources/ContainerCommands/Registry/RegistryLogin.swift`, `RegistryLogout.swift` — credential storage in keychain service `com.apple.container.registry` (`Constants.keychainID`), how the server/hostname key is derived; `--username`, `--password-stdin`, `--scheme`.
- `Sources/Services/ContainerAPIService/Client/RequestScheme.swift`.
- `ClientImage.swift` — `push(platform:scheme:containerSystemConfig:progressUpdate:)`, `static save(references:out:platform:containerSystemConfig:)`, `static load(from:force:)`.
- `Sources/ContainerCommands/Image/ImagePush.swift`, `ImageSave.swift`, `ImageLoad.swift`.

## Files
- `Sources/DockyardCore/Registry/RegistryCredentials.swift` — keychain add/update/delete/list using the same service/account layout as upstream so CLI and app share logins.
- `Backend/ContainerBackend.swift` — `pushImage(reference:platform:) -> AsyncThrowingStream<PullProgress,Error>` (reuse progress model), `saveImages(references:to:)`, `loadImage(from:)`.
- `Stores/ImageStore.swift` — `push`, `save`, `load`.
- `Dockyard/Images/RegistryLoginSheet.swift` — registry host, username, password (SecureField), scheme; list of logged-in registries with Logout.
- `Dockyard/Images/PushSheet.swift` — target reference (defaults to current), platform; progress rows.
- Save: `NSSavePanel` → `.tar`. Load: toolbar "Load from tar…" (`NSOpenPanel`).

## Acceptance
- [ ] Login to a local registry (`registry:2` run via T11 with `5000:5000`, scheme http) → tag `alpine` as `localhost:5000/alpine:t` → Push → registry `/v2/_catalog` lists it.
- [ ] `container registry login` state from the CLI shows in the app's list (shared keychain).
- [ ] Save `alpine:3.20` to tar → Load it back after deleting → image row returns.

## Notes
