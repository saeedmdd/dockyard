import Foundation
import Testing

@testable import DockyardCore

@Suite struct ComposePlannerTests {

    private func spec(
        _ yaml: String,
        directory: String = "/Users/me/shop",
        environment: [String: String] = [:]
    ) throws -> ComposeProjectSpec {
        let file = URL(fileURLWithPath: "\(directory)/compose.yaml")
        let (parsed, diagnostics) = ComposeParser.parse(
            yaml: yaml, projectName: "shop", fileURL: file, environment: environment
        )
        return try #require(parsed, "diagnostics: \(diagnostics.map(\.display))")
    }

    private func plan(_ yaml: String, dnsDomain: String? = "test", directory: String = "/Users/me/shop")
        throws -> ComposeUpPlan
    {
        try ComposePlanner.plan(spec(yaml, directory: directory), dnsDomain: dnsDomain).get()
    }

    // MARK: - The invariants that must never change

    @Test func everySpecLandsOnTheDefaultNetwork() throws {
        let plan = try plan("services:\n  web: { image: nginx }\n  db: { image: postgres }\n")
        // Empty means the runtime attaches `default`, the only network where
        // containers can resolve each other by name.
        #expect(plan.steps.allSatisfy { $0.spec.networks.isEmpty })
    }

    /// Even when the file asks for networks — T22 reports that it was ignored.
    @Test func aRequestedNetworkIsStillNotAttached() throws {
        let plan = try plan("services:\n  web:\n    image: nginx\n    networks: [backend]\n")
        #expect(plan.steps[0].spec.networks.isEmpty)
    }

    @Test func containersNeverDeleteThemselves() throws {
        let plan = try plan("services:\n  web: { image: nginx }\n")
        #expect(plan.steps.allSatisfy { !$0.spec.removeWhenStopped })
        #expect(plan.steps.allSatisfy { !$0.spec.startImmediately })
    }

    @Test func containersAreNamedProjectThenService() throws {
        let plan = try plan("services:\n  web: { image: nginx }\n  db: { image: postgres }\n")
        #expect(plan.steps.map(\.containerID).sorted() == ["shop-db", "shop-web"])
        #expect(plan.steps.allSatisfy { EntityName.isValid($0.containerID) })
    }

    @Test func stepsComeBackInDependencyOrder() throws {
        let plan = try plan("""
            services:
              web:
                image: nginx
                depends_on: [db]
              db: { image: postgres }
            """)
        #expect(plan.steps.map(\.service) == ["db", "web"])
        #expect(plan.stopOrder.map(\.service) == ["web", "db"])
    }

    @Test func aCycleRefusesTheWholePlan() throws {
        let project = try spec("""
            services:
              a:
                image: alpine
                depends_on: [b]
              b:
                image: alpine
                depends_on: [a]
            """)
        guard case .failure(let error) = ComposePlanner.plan(project, dnsDomain: "test") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.message.contains("loop"))
    }

    // MARK: - The config hash

    /// The trap this test exists for: `RunSpec.KeyValue.id` is a fresh `UUID`
    /// and is `Codable`, so hashing an encoded `RunSpec` yields a new digest
    /// every run — and `up` would delete and recreate every container every
    /// time, losing whatever state lived inside them.
    @Test func theHashIsStableAcrossTwoIndependentPlans() throws {
        let yaml = """
            services:
              web:
                image: nginx
                environment:
                  A: "1"
                  B: "2"
                ports: ["8080:80"]
                volumes: ["data:/var/lib/data"]
            """
        let first = try plan(yaml)
        let second = try plan(yaml)
        #expect(first.steps[0].configHash == second.steps[0].configHash)
        #expect(!first.steps[0].configHash.isEmpty)
    }

    /// Proof the trap is real, not theoretical.
    @Test func encodingTheRunSpecWouldNotHaveBeenStable() throws {
        let a = try plan("services:\n  web:\n    image: nginx\n    environment: { A: \"1\" }\n").steps[0].spec
        let b = try plan("services:\n  web:\n    image: nginx\n    environment: { A: \"1\" }\n").steps[0].spec
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(
            try encoder.encode(a) != encoder.encode(b),
            "if this ever becomes equal, the KeyValue.id UUID is gone and the canonical projection could be simplified"
        )
    }

    @Test(arguments: [
        ("image", "services:\n  web: { image: nginx:1.27 }\n"),
        ("environment", "services:\n  web:\n    image: nginx\n    environment: { A: changed }\n"),
        ("ports", "services:\n  web:\n    image: nginx\n    ports: [\"9090:80\"]\n"),
        ("volumes", "services:\n  web:\n    image: nginx\n    volumes: [\"other:/data\"]\n"),
        ("command", "services:\n  web:\n    image: nginx\n    command: sleep 1\n"),
        ("restart", "services:\n  web:\n    image: nginx\n    restart: always\n"),
    ])
    func theHashChangesWhenAnythingThatMattersChanges(_ what: String, _ changed: String) throws {
        let base = try plan("services:\n  web: { image: nginx }\n").steps[0].configHash
        let after = try plan(changed).steps[0].configHash
        #expect(base != after, "changing \(what) must change the hash")
    }

    /// Reordering a file without changing its meaning must not recreate
    /// containers.
    @Test func reorderingWithoutChangingMeaningKeepsTheHash() throws {
        let one = try plan("""
            services:
              web:
                image: nginx
                environment:
                  B: "2"
                  A: "1"
            """).steps[0].configHash
        let two = try plan("""
            services:
              web:
                image: nginx
                environment:
                  A: "1"
                  B: "2"
            """).steps[0].configHash
        #expect(one == two)
    }

    // MARK: - Volumes and paths

    @Test func namedVolumesArePrefixedWithTheProject() throws {
        let plan = try plan("""
            services:
              db:
                image: postgres
                volumes: ["pgdata:/var/lib/postgresql/data"]
            volumes:
              pgdata:
            """)
        #expect(plan.steps[0].spec.volumes == ["shop_pgdata:/var/lib/postgresql/data"])
        #expect(plan.ownedVolumes == ["shop_pgdata"])
    }

    /// An external volume belongs to somebody else — it keeps its name and
    /// `down` must never remove it.
    @Test func anExternalVolumeIsNeitherRenamedNorOwned() throws {
        let plan = try plan("""
            services:
              db:
                image: postgres
                volumes: ["shared:/data"]
            volumes:
              shared:
                external: true
            """)
        #expect(plan.steps[0].spec.volumes == ["shared:/data"])
        #expect(plan.ownedVolumes.isEmpty)
    }

    @Test func relativeBindSourcesAreResolvedAgainstTheComposeFile() throws {
        let plan = try plan(
            "services:\n  web:\n    image: nginx\n    volumes: [\"./site:/usr/share/nginx/html:ro\"]\n",
            directory: "/Users/me/shop"
        )
        #expect(plan.steps[0].spec.volumes == ["/Users/me/shop/site:/usr/share/nginx/html:ro"])
    }

    @Test func anAnonymousVolumeIsJustADestination() throws {
        let plan = try plan("services:\n  web:\n    image: nginx\n    volumes: [\"/scratch\"]\n")
        #expect(plan.steps[0].spec.volumes == ["/scratch"])
    }

    // MARK: - Names

    @Test func theProjectNameIsSanitised() throws {
        let project = try spec("name: My Shop!\nservices:\n  web: { image: nginx }\n")
        let plan = try ComposePlanner.plan(project, dnsDomain: "test").get()
        #expect(plan.projectName == "my-shop")
        #expect(plan.steps[0].containerID == "my-shop-web")
    }

    /// The FQDN becomes a DNS label, and silently exceeding 63 characters
    /// produces a name nothing resolves — which reads as a networking bug.
    @Test func anOverLongNameIsRefusedWithTheLimitNamed() throws {
        let long = String(repeating: "a", count: 55)
        let project = try spec("name: \(long)\nservices:\n  web: { image: nginx }\n")
        guard case .failure(let error) = ComposePlanner.plan(project, dnsDomain: "test") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.message.contains("63"))
    }

    // MARK: - Hostname rewriting and DNS

    @Test func rewritingIsAppliedAndRecorded() throws {
        let plan = try plan("""
            services:
              web:
                image: nginx
                environment:
                  DATABASE_URL: postgres://db:5432/app
              db: { image: postgres }
            """)
        let web = try #require(plan.steps.first { $0.service == "web" })
        #expect(
            web.spec.environment.first { $0.key == "DATABASE_URL" }?.value
                == "postgres://shop-db.test:5432/app"
        )
        #expect(plan.rewrites.map(\.key) == ["DATABASE_URL"])
    }

    @Test func aServiceCanOptOut() throws {
        let plan = try plan("""
            services:
              web:
                image: nginx
                x-dockyard: { rewrite: false }
                environment:
                  DATABASE_URL: postgres://db:5432/app
              db: { image: postgres }
            """)
        let web = try #require(plan.steps.first { $0.service == "web" })
        #expect(web.spec.environment.first { $0.key == "DATABASE_URL" }?.value == "postgres://db:5432/app")
        #expect(plan.rewrites.isEmpty)
    }

    /// Rewriting a name to something equally unresolvable would hide the real
    /// problem, which is that no domain is configured at all.
    @Test func withNoDNSDomainNothingIsRewrittenAndTheProblemIsReported() throws {
        let plan = try plan(
            """
            services:
              web:
                image: nginx
                environment:
                  DATABASE_URL: postgres://db:5432/app
              db: { image: postgres }
            """,
            dnsDomain: nil
        )
        let web = try #require(plan.steps.first { $0.service == "web" })
        #expect(web.spec.environment.first { $0.key == "DATABASE_URL" }?.value == "postgres://db:5432/app")
        #expect(plan.rewrites.isEmpty)
        #expect(plan.diagnostics.contains { $0.message.contains("cannot reach each other by name") })
    }

    // MARK: - Labels

    @Test func everyContainerCarriesItsProjectLabels() throws {
        let plan = try plan("""
            services:
              web:
                image: nginx
                depends_on: [db]
                restart: always
                labels:
                  mine: keep
              db: { image: postgres }
            """)
        let web = try #require(plan.steps.first { $0.service == "web" })
        let labels = Dictionary(uniqueKeysWithValues: web.spec.labels.map { ($0.key, $0.value) })

        #expect(labels[ComposeLabels.project] == "shop")
        #expect(labels[ComposeLabels.service] == "web")
        #expect(labels[ComposeLabels.configHash] == web.configHash)
        #expect(labels[ComposeLabels.dependsOn] == "db")
        #expect(labels[ComposeLabels.restart] == "always")
        // The user's own labels survive alongside ours.
        #expect(labels["mine"] == "keep")
    }
}
