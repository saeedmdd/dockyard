# T23 — Hostname rewriting

**Milestone:** M6 · **Depends on:** T22 · **Status:** done

Pure code. The piece most likely to burn someone, so it is deliberately conservative and every
change it makes is recorded.

## Why this exists
On `apple/container` a bare `db` never resolves — only `db.<domain>` does, and only on the `default`
network. `AttachmentOptions` takes a single hostname and there is no alias mechanism, so a container
has exactly one resolvable name. A stock compose file's
`DATABASE_URL=postgres://user:pass@db:5432/app` therefore fails silently. Dockyard names containers
`<project>-<service>`, so the value has to become `<project>-<service>.<domain>`.

## The rule
A value containing `://` is treated as a URL and gets **tier A** only; anything else gets **tier B**.

- **Tier A — URL authority, any key.** Regex `(//)([^/@\s]*@)?([A-Za-z0-9_.\-]+)`, replacing only the
  host capture and only on an exact service-name match. A regex rather than `URLComponents`, because
  `URLComponents(string: "jdbc:postgresql://db:5432/app")?.host` is nil — JDBC, `mongodb+srv` and
  anything else with a scheme-specific part falls out of it. Replacing a captured range leaves
  credentials, port, path and query byte-identical.
- **Tier B — bare `host` or `host:port`, host-shaped keys only.** The whole comma/whitespace-separated
  piece must be `service` or `service:port`, **and** the key must look like a host
  (`HOST`, `ADDR`, `SERVER`, `ENDPOINT`, `URL`, `BROKER`, …) and must not look like something else
  (`USER`, `PASS`, `SECRET`, `NAME`, `DB`, `PATH`, …). Deny beats allow.
- **Tier C — nothing.** No free-text substitution anywhere. `command`, `entrypoint`, mount paths and
  label values are never touched.

## Accepted failure modes
- `POSTGRES_USER=db` is **not** rewritten — answered by the key rule, not by inspecting the value.
- `BACKEND=api`, a genuine hostname under an unhelpful key, is **not** rewritten. It is surfaced as a
  *candidate* so the user can see it and rename the key or opt in.
- A hostname inside a mounted config file is never rewritten. We do not edit the user's files.

## Files
- `Compose/ComposeHostnames.swift`

## Acceptance
- [x] Every row of the failure-mode table behaves as stated, table-driven.
- [x] Credentials, port, path and query survive byte-for-byte, including an **unencoded `@` in a
      password** — `postgres://user:p@ss=w0rd@db:5432/app?sslmode=require`.
- [x] `jdbc:postgresql://db:5432/app` is rewritten, and the test first asserts that
      `URLComponents(string:)?.host` really is nil for it, so the reason for the regex is recorded.
- [x] A comma-separated broker list rewrites every piece and preserves the separators, with or
      without spaces after the commas.
- [x] Idempotent across all four shapes — URL, bare host, host:port, broker list.
- [x] `x-dockyard.rewrite: false` is parsed in T22 and honoured by the caller; the rewriter itself is
      a pure function the planner chooses to apply.
- [x] Every change is an auditable `HostnameRewrite` carrying both sides and which rule fired.
- [x] Candidates are **only** genuinely ambiguous keys — see findings.
- [x] End to end on the realistic stack: the host in `postgres://db:secret@db:5432/shop` is rewritten
      while the identical username `db` beside it is not.
- [x] 407 unit tests in 57 suites; `xcodebuild` clean.

## Findings

Three design flaws, all caught by tests written before the code was trusted:

- **Deny-by-substring rejected the commonest hostname keys there are.** `DB` and `DATABASE` are on the
  deny list, so `DB_HOST`, `DATABASE_URL` and `POSTGRES_HOST` were all refused. The **last**
  underscore-separated segment decides now, because that is where a key's meaning lives: `DB_HOST` is
  a host, `DB_USER` is not, and both start with `DB`.
- **Deny had to match a whole segment, not a substring.** With `contains`, `NAME` rejected `HOSTNAME`
  and `KEY` would reject `HOSTKEY`. Allow still matches as a substring, so `KAFKA_BROKERS` and
  `PGHOST` work.
- **Splitting tier B on whitespace corrupted prose.** `APP_HOST="the db is over there"` had its middle
  word rewritten. Commas only now — a comma-separated broker list is a real shape, a space-separated
  one is not — so a piece with internal whitespace can never match.
- **The userinfo group had to allow `@`.** An unencoded `@` in a password is invalid but common, and
  the original `[^/@\s]*@` stopped at the first one, leaving the wrong capture as the host. It is
  greedy now but still excludes `/`, so it can never run past the authority into a path.

And one judgement call worth recording: **a candidate is only reported for an *ambiguous* key.**
Reporting every value that merely equals a service name meant `POSTGRES_USER=db`, `POSTGRES_DB=db` and
`APP_NAME=web` all appeared in the pane, burying the single entry a user actually has to look at. A
deny-listed key is one we are confident about, and a service naming itself is never a hostname anyone
needs, so both are silent. `BACKEND=api` — neither allowed nor denied — is what the pane is for.

## Notes
