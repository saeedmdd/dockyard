# T21 — Compose plumbing: Yams, label-scoped listing, DNS reads

**Milestone:** M6 · **Depends on:** T20 · **Status:** done

No user-visible change. This is the substrate every later compose task needs, kept separate so the
risky parts land against a green base.

## Upstream references
- `Sources/ContainerResource/Container/ContainerListFilters.swift` — `labels` values are **regular
  expressions** matched against the container's label value; a missing label matches as the empty
  string. `.withoutMachines()` merges in the plugin exclusion, so it composes with ours.
- `Sources/ContainerK8s/Commands/K8sList.swift` — the in-repo precedent for listing by a plugin label.
- `Sources/ContainerResource/Common/ManagedResource.swift` — reverse-DNS label keys are the convention.
- `Sources/Services/ContainerAPIService/Client/HostDNSResolver.swift` — `listDomains()`; `createDomain`
  writes `/etc/resolver/…` and is host-side only.
- `Package.swift:73` — Yams 6.2.x is already in the graph, not re-exported.

## Files
- `Packages/DockyardCore/Package.swift` — declare Yams. Leave the `containerVersion` line untouched;
  `PinnedVersionTests` parses it.
- `Backend/ContainerBackend.swift`, `LiveBackend.swift`, `Tests/.../MockBackend.swift` —
  `listContainers(matchingLabels:)`, `dnsDomain()`, `hostResolverDomains()`.
- `Compose/ComposeLabels.swift` — label vocabulary + `exactly(_:)` wrapping
  `NSRegularExpression.escapedPattern` in anchors.

## Acceptance
- [x] Yams parses a document **with positions** (`Yams.compose` → `Node.mark`), which is what later
      diagnostics need. `PinnedVersionTests` unaffected — the `containerVersion` line was not touched.
- [x] `listContainers(matchingLabels:)` verified against the real daemon: two labelled containers
      found, a third unlabelled one left alone.
- [x] **A project name containing regex metacharacters matches only itself.** Table-driven over
      `my.proj`, `a+b`, `web(1)`, `cache[0]`, `a|b`, `v1.2.3`, `x*y`, `^start`, `end$`, each checked
      against the string its unescaped form would have matched.
- [x] The blast-radius case end to end: project `my.proj` with `myXproj`, `my.proj.staging` and an
      unlabelled decoy — the filter returns exactly the two that belong to it.
- [x] A container with no project label is excluded, both in the mock and against the daemon.
- [x] `dnsDomain()` is nil here and `hostResolverDomains()` is empty — confirmed independently:
      `container system property list` shows an empty `[dns]` section and `/etc/resolver` does not
      exist. This is the state the prerequisite sheet in T25 has to detect.
- [x] The mock evaluates the regex against stored labels, missing label as empty string.
- [x] 326 unit tests in 48 suites, 60 integration tests; `xcodebuild` clean; zero leftovers.

## Findings

- **The mock had to be taught to sort.** Its first version returned insertion order while
  `LiveBackend` sorts every list it returns, so an order-dependent expectation passed against the
  mock and would have failed against the daemon. The mock now mirrors the sort.
- **String equality in the mock would have made the escaping test worthless.** It evaluates the
  pattern with `NSRegularExpression`, matching a missing label as the empty string exactly as the
  runtime documents, so the `my.proj` test is actually exercising the thing it claims to.
- `config.dns.domain` is optional *and* can be an empty string depending on how it was written;
  `dnsDomain()` reports both as nil, so callers have one thing to check rather than two.
- `HostDNSResolver().listDomains()` needs no privileges — only `createDomain` does. Reading it is
  therefore safe to do on every poll, which T25 depends on.

## Notes
