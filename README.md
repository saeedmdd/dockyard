# Dockyard

A native macOS app for [`apple/container`](https://github.com/apple/container), Apple's Linux
container runtime. See your containers and images, pull and build images, run containers, read their
logs, open a shell in them, and manage volumes, networks and registries — without leaving the GUI.

Dockyard is a front end, not a runtime. It links the same XPC client libraries the `container`
command uses and talks to the same `container-apiserver`, so it is not spawning a CLI process per
refresh and there is no daemon of its own to keep alive. It idles at roughly zero CPU: polling stops
entirely when the window is hidden.

<!-- TODO: screenshots — Containers list, container detail with logs, the Run sheet, System panel. -->

## Requirements

| | |
|---|---|
| macOS | 26 or later |
| Mac | Apple Silicon — `apple/container` boots Linux VMs through Virtualization.framework |
| `apple/container` | 1.0.0, installed from Apple's package |

Dockyard does **not** bundle the runtime. Install Apple's package first.

## Install

1. Install `apple/container` from its
   [releases page](https://github.com/apple/container/releases) and run the installer.
2. Download `Dockyard-<version>.dmg` from this project's releases, open it, and drag Dockyard to
   Applications.
3. Open Dockyard.

## First launch

`container-apiserver` is not running until something starts it. Dockyard notices and shows you a
Start button rather than an empty list — pressing it runs `container system start`, which registers
the service with launchd so it comes back after a reboot. Everything else fills in once it is up.

From there: **Images ▸ Pull Image…** (⌘⇧P) to fetch something, then **Run** (⌘N) to start a
container from it. The container's detail pane has its logs, live CPU and memory, and a terminal.

## Keyboard shortcuts

| | |
|---|---|
| ⌘1 – ⌘5 | Containers, Images, Volumes, Networks, System |
| ⌘N | Run a container |
| ⌘⇧P / ⌘B | Pull / build an image |
| ⌘F / ⌘⇧F | Search the list / search the open container's logs |
| ⌘↩ / ⌘. | Start / stop the selected container |
| ⌘⌫ | Delete what is selected, with a confirmation |
| ⌘R | Refresh now |

## Version compatibility

Dockyard links Apple's client libraries at an exact version and checks what the running server
reports. A mismatch is a banner, not a crash — most things still work — but the pairing below is the
tested one.

| Dockyard | `apple/container` |
|---|---|
| 0.1.0 | 1.0.0 |

## Building from source

Needs Xcode 26 or later — Apple's package requires Swift 6.2 — and the Metal Toolchain, which
SwiftTerm's build plugin depends on. Built and tested here with Xcode 27.0 on macOS 26.6.

```sh
xcodebuild -downloadComponent MetalToolchain
git clone <this repo> && cd macos-comtainer
xcodebuild -project Dockyard.xcodeproj -scheme Dockyard -configuration Debug \
    -skipPackagePluginValidation build
```

The first build resolves about 200 MB across 16 packages and takes a while.

Tests:

```sh
cd Packages/DockyardCore
swift test                                              # unit tests, no daemon needed
DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests   # needs a running daemon
```

The integration tests create and delete containers, images, volumes and networks on the machine they
run on, each under a unique `dockyard-it-…` prefix, and clean up after themselves including on
failure. The destructive sweeps — pruning every stopped container or every unused image, and
restarting the daemon — are held behind `DOCKYARD_DESTRUCTIVE=1` so a normal run cannot take a
developer's work with it.

## Releasing

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: You (TEAM12345)" \
TEAM_ID=TEAM12345 \
scripts/release.sh
```

That archives, signs, notarizes and staples, then builds `build/Dockyard-<version>.dmg` and
notarizes the image too. Notarization needs credentials stored once:

```sh
xcrun notarytool store-credentials DOCKYARD_NOTARY \
    --apple-id you@example.com --team-id TEAM12345 --password <app-specific-password>
```

Without `DEVELOPER_ID_APPLICATION` the same command still produces a DMG, signed ad-hoc and not
notarized. That is fine for testing on the machine that built it and will be refused by Gatekeeper
anywhere else — the script says so as it goes.

Pushing a `v*` tag runs the same scripts on a `macos-26` runner and publishes the DMG as a GitHub
release. It signs and notarizes only if the repository has `MACOS_CERTIFICATE_P12`,
`MACOS_CERTIFICATE_PASSWORD`, `DEVELOPER_ID_APPLICATION`, `TEAM_ID`, `NOTARY_APPLE_ID` and
`NOTARY_PASSWORD` set; without them it builds ad-hoc and says so in the release notes.

## How it is put together

`Packages/DockyardCore` holds the models, the stores and the one type that knows Apple's API shapes
(`LiveBackend`); `Dockyard/` is the SwiftUI layer. No view imports `ContainerAPIClient`, so the
upstream dependency can be moved in a single file and the UI compiles without it.

Two jobs go through the `container` CLI rather than XPC, both deliberately: starting and stopping the
system, because that writes a launchd plist Apple's installer owns, and building images, because
upstream's build pipeline lives in the CLI and not in a reusable library.

[`docs/PLAN.md`](docs/PLAN.md) has the full design and the decisions behind it.
[`docs/WORKFLOW.md`](docs/WORKFLOW.md) is how changes get made, and
[`docs/tasks/`](docs/tasks/) is the task-by-task record, including what did not work and why.

## Known limitations

- **Building an image needs a working buildkit.** Dockyard shells out to `container build`, so a
  build that fails from the CLI fails here too, with the same message.
- **Launch at login needs a signed build.** `SMAppService` refuses a bundle the system does not
  recognise; the Settings window says so rather than showing a toggle that springs back.
- **No event API upstream**, so the lists are polled — every two seconds by default, adjustable in
  Settings, and paused whenever the window is hidden.

## License

Apache-2.0, matching `apple/container`. See [LICENSE](LICENSE).
