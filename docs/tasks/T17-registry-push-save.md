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
- [x] Save → load round trip verified against the real runtime, on a fixture-owned tag.
- [x] Loading something that is not a tar archive fails rather than silently doing nothing.
- [x] Reading the keychain works with nothing stored (an error there would look like "no registries").
- [x] Signing out of something never signed in **fails with a readable message** — see findings.
- [x] Pushing a reference that does not exist fails fast.
- [x] 257 unit tests in 39 suites, 50 integration tests; `xcodebuild` clean.
- [ ] **A successful push could not be verified here** — see below. The test is kept and gated.

## Findings

- **Bug in my own test isolation, found by the suite going red.** The archive round trip originally
  saved and loaded the shared `alpine:3.20`. Loading an archive rewrites the image's index descriptor
  to carry name annotations, so while that test ran, every other test creating a container from
  `alpine:3.20` failed with `descriptor mismatch: expected … annotations: nil, got … annotations:
  [...]`. It looked like a corrupted machine — re-pulling the image did not help — until the CLI was
  tried and created a container from the same image without complaint. That ruled out the
  environment and pointed at concurrency between my own tests. The archive test now round-trips a
  fixture-owned tag and touches nothing shared.
- **`auto` is the wrong scheme for a registry on this Mac.** `container image push` to
  `127.0.0.1:15000` fails with `I/O on closed channel`, which says nothing about TLS; with
  `--scheme http` it proceeds. The scheme was hard-coded to `.auto`, so push and login now take one,
  and the push sheet warns when a localhost target is left on Automatic.
- **The keychain's delete succeeds silently when nothing matches**, so signing out of a registry that
  was never signed in reported success. The backend checks the list first and reports `notFound`.
  The mock had been throwing all along, so mock and reality disagreed — the integration test is what
  exposed it.
- Credentials are checked against the registry before being written, so a wrong password fails at
  sign-in rather than confusingly at push time. They live in the login keychain under
  `com.apple.container.registry`, the same service the CLI uses, so a login made in either is visible
  to both.

## Blocked: pushing hangs on this machine
`container image push` against a local `registry:2` hangs, from the CLI as well as from Dockyard:

- `container image push 127.0.0.1:15000/x:1` → `I/O on closed channel`
- `container image push --scheme http 127.0.0.1:15000/x:1` → uploads, then sits at 0% indefinitely

That comparison is what produced the scheme handling above, so the investigation was worthwhile even
though the push itself could not be completed. `pushToALocalRegistrySucceeds` is kept, disabled with
that reason, and will run wherever pushing works.

## Notes
