import Foundation
import Testing
import Yams

@testable import DockyardCore

/// The substrate compose needs, against the real runtime.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct ComposePlumbingTests {

    /// Yams is reached transitively through apple/container, so this asserts the
    /// manifest change actually exposes it — a build error would say so, but a
    /// silently stale resolution would not.
    @Test func yamsParsesACompositeDocumentWithPositions() throws {
        let yaml = """
            services:
              web:
                image: nginx:alpine
                ports: ["8080:80"]
            """
        let node = try #require(try Yams.compose(yaml: yaml))
        let services = try #require(node.mapping?["services"]?.mapping)
        #expect(services.keys.contains(where: { $0.string == "web" }))

        // Line numbers are the reason for `compose` over a plain decode: a
        // diagnostic has to point at the offending line.
        let web = try #require(services["web"])
        #expect(web.mark != nil)
    }

    @Test func labelledContainersAreFoundByTheirProjectLabel() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            let project = fixture.prefix

            var web = fixture.sleeperSpec("web")
            web.labels = [
                .init(key: ComposeLabels.project, value: project),
                .init(key: ComposeLabels.service, value: "web"),
            ]
            var db = fixture.sleeperSpec("db")
            db.labels = [
                .init(key: ComposeLabels.project, value: project),
                .init(key: ComposeLabels.service, value: "db"),
            ]
            // A container in no project at all, which must never be swept up.
            let loose = fixture.sleeperSpec("loose")

            try await fixture.create(web)
            try await fixture.create(db)
            try await fixture.create(loose)

            let listed = try await fixture.backend.listContainers(
                matchingLabels: ComposeLabels.filter(project: project)
            )

            #expect(listed.map(\.id).sorted() == [fixture.name("db"), fixture.name("web")])
            #expect(!listed.contains { $0.id == fixture.name("loose") })
        }
    }

    /// Narrowing by a second label is how a per-service lookup works.
    @Test func severalLabelsAllHaveToMatch() async throws {
        try await withFixture { fixture in
            try await fixture.ensureTestImage()
            var web = fixture.sleeperSpec("web")
            web.labels = [
                .init(key: ComposeLabels.project, value: fixture.prefix),
                .init(key: ComposeLabels.service, value: "web"),
            ]
            try await fixture.create(web)

            let matched = try await fixture.backend.listContainers(matchingLabels: [
                ComposeLabels.project: ComposeLabels.exactly(fixture.prefix),
                ComposeLabels.service: ComposeLabels.exactly("web"),
            ])
            #expect(matched.map(\.id) == [fixture.name("web")])

            let missed = try await fixture.backend.listContainers(matchingLabels: [
                ComposeLabels.project: ComposeLabels.exactly(fixture.prefix),
                ComposeLabels.service: ComposeLabels.exactly("db"),
            ])
            #expect(missed.isEmpty)
        }
    }

    /// Both halves of the DNS story, read without privileges. On a machine with
    /// nothing configured both are empty — which is the state the prerequisite
    /// sheet has to detect and explain.
    @Test func theDNSStateIsReadableWithoutPrivileges() async throws {
        try await ensureDaemonRunning()
        let backend = LiveBackend()

        let domain = try await backend.dnsDomain()
        let resolvers = backend.hostResolverDomains()

        if let domain {
            #expect(!domain.isEmpty, "an unset domain must be reported as nil, not as empty text")
        }
        // Asserting a shape, not a value: a developer who has configured DNS
        // should not get a red suite for it.
        #expect(resolvers.allSatisfy { !$0.isEmpty })
    }
}

/// The DNS prerequisite read against this machine, whatever state it is in.
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct ComposeDNSIntegrationTests {

    @Test func theStateIsReadableWithoutPrivileges() async throws {
        try await ensureDaemonRunning()
        let backend = LiveBackend()

        let state = ComposeDNSSetup.state(
            effectiveDomain: try await backend.dnsDomain(),
            resolverDomains: backend.hostResolverDomains(),
            onDiskDomain: ComposeDNSSetup.onDiskDomain()
        )

        // Asserting a shape rather than a value: a developer who has configured
        // DNS must not get a red suite for it.
        #expect(!state.summary.isEmpty)
        switch state {
        case .notConfigured:
            #expect(!state.containersCanResolveEachOther)
        case .restartPending(let domain), .hostResolverMissing(let domain), .ready(let domain):
            #expect(ComposeDNSSetup.validate(domain: domain) == nil, "the live domain must be a valid one")
        }
    }

    /// Reading the user's real config file must never throw, whether or not it
    /// exists — this runs on every visit to the project screen.
    @Test func readingTheRealConfigIsSafeWhetherOrNotItExists() {
        _ = ComposeDNSSetup.onDiskDomain()
        #expect(ComposeDNSSetup.userConfigURL.path.hasSuffix(".config/container/config.toml"))
    }

    /// The planned edit is computed against the real file but **not applied**,
    /// so this reports what would happen without changing the machine.
    @Test func thePlannedEditForThisMachineIsSensible() {
        let edit = ComposeDNSSetup.plannedEdit(domain: ComposeDNSSetup.defaultDomain)
        switch edit {
        case .create(_, let contents):
            #expect(contents.contains("domain = \"test\""))
        case .append(_, let addition, _):
            #expect(addition.contains("[dns]"))
        case .refuse(_, let reason):
            #expect(reason.contains("[dns]"))
        }
    }
}
