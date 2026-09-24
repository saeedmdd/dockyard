# T26 — The DNS prerequisite

**Milestone:** M6 · **Depends on:** T25 · **Status:** done

Without a DNS domain, containers cannot reach each other by name and a compose file is close to
useless. This detects the state and does as much of the setup as it can without privileges.

## What actually needs privileges
Only one thing, and **not the one that makes compose work**:

- `~/.config/container/config.toml` is owned by the user. Writing `[dns] domain = "test"` there
  needs nothing special. This is what the daemon hands containers, so it is what makes
  container-to-container resolution work.
- The daemon has to restart to re-read it — `ConfigurationLoader.copyConfigurationToReadOnly` runs
  from `SystemStart`, so the copy is the restart's job.
- `sudo container system dns create <domain>` writes `/etc/resolver/containerization.<domain>` and
  HUPs mDNSResponder. That is **host-side only**: it lets *you* `curl myproj-web.test` from this Mac.
  Containers do not need it.

So the privileged step is optional and must never gate the first `up`.

## Files
- `Compose/ComposeDNS.swift`

## Acceptance
- [x] The four states are a pure function of the three reads, including the edge cases: an empty
      string counts as unset, and a resolver entry with a trailing dot still counts as present.
- [x] `containersCanResolveEachOther` is true for `hostResolverMissing` — the half that matters for
      compose — and false for `restartPending`, so the UI can tell "nearly there" from "not yet".
- [x] A missing file is created; one without a `[dns]` table is appended to after a backup, with the
      original settings surviving byte-for-byte at the top and the backup holding the old contents.
- [x] A file that already has a `[dns]` table is refused, and the file is verified untouched.
- [x] Validation refuses `local` **by name and with the reason**, anything with a dot, and anything
      that is not a plain DNS label.
- [x] The command and its AppleScript wrapper are asserted **without triggering an authorization
      prompt**, including a path containing a single quote.
- [x] Verified against this machine's real state — no domain, no resolver, no config file — and the
      planned edit is computed without applying it, so the run changes nothing.
- [x] 463 unit tests in 65 suites, 68 integration tests; `xcodebuild` clean; `config.toml` still
      absent afterwards.

## Findings

- **Only one of the three steps needs privileges, and it is not the one that makes compose work.**
  Writing `~/.config/container/config.toml` is a user-owned file, and that is what the daemon hands
  containers. `container system dns create` writes `/etc/resolver/…` so that *this Mac* can resolve
  container names — useful, but never a reason to block the first `up`. The state machine encodes
  that: `hostResolverMissing` reports `containersCanResolveEachOther == true`.
- **Appending a new table at the end of the file is the only TOML edit that provably cannot change
  an existing one**, which is why the write path does that rather than round-tripping a parser — and
  why no TOML writing dependency was added. A file that already has a `[dns]` table is refused
  outright; machine-editing somebody's hand-written configuration is not worth the branch it saves.
- `.local` is refused by name because Bonjour owns it, and taking it over breaks printers, AirPlay
  and everything else on the network. A generic "invalid domain" would leave the user guessing.
- The two `NSAppleScript` traps — main thread only, and it blocks until the user answers — are
  recorded on `appleScript(forPrivileged:)` itself, since neither is visible at the call site.

## Notes
