import Foundation
import Testing

@testable import DockyardCore

@MainActor
@Suite struct ComposeUpTests {

    private func plan(
        _ yaml: String = """
            services:
              web:
                image: nginx
                depends_on: [db]
              db: { image: postgres }
            """
    ) throws -> ComposeUpPlan {
        let (spec, _) = ComposeParser.parse(
            yaml: yaml,
            projectName: "shop",
            fileURL: URL(fileURLWithPath: "/tmp/shop/compose.yaml"),
            environment: [:]
        )
        return try ComposePlanner.plan(try #require(spec), dnsDomain: "test").get()
    }

    /// A container as it would exist after a previous `up`.
    private func existing(
        _ service: String,
        hash: String,
        status: ContainerStatus = .running,
        project: String = "shop"
    ) -> ContainerItem {
        .stub(
            id: "\(project)-\(service)",
            status: status,
            labels: [
                ComposeLabels.project: project,
                ComposeLabels.service: service,
                ComposeLabels.configHash: hash,
            ]
        )
    }

    private func settled(_ job: ComposeJob) async {
        while !job.isFinished { await Task.yield() }
    }

    @Test func createsAndStartsInDependencyOrder() async throws {
        let backend = MockBackend()
        let store = ComposeStore(backend: backend)

        let job = store.up(try plan())
        await settled(job)

        #expect(job.state == .succeeded)
        #expect(job.steps.map(\.service) == ["db", "web"])
        #expect(job.steps.allSatisfy { $0.status == .ready })
        // Created in order, and each started after it was created.
        let created = backend.invocations.filter { $0.action == "create" }.map(\.id)
        #expect(created == ["shop-db", "shop-web"])
        let started = backend.invocations.filter { $0.action == "start" }.map(\.id)
        #expect(started == ["shop-db", "shop-web"])
    }

    /// The point of the config hash: an unchanged project must not be rebuilt.
    @Test func asecondUpWithNoChangesCreatesNothing() async throws {
        let plan = try plan()
        let hashes = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.service, $0.configHash) })
        let backend = MockBackend(containers: [
            existing("db", hash: hashes["db"] ?? ""),
            existing("web", hash: hashes["web"] ?? ""),
        ])
        let store = ComposeStore(backend: backend)

        let job = store.up(plan)
        await settled(job)

        #expect(job.state == .succeeded)
        #expect(job.steps.allSatisfy { $0.status == .reused })
        #expect(backend.calls.createContainer == 0)
        #expect(backend.calls.start == 0)
    }

    @Test func anExistingButStoppedServiceIsStartedNotRecreated() async throws {
        let plan = try plan()
        let hashes = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.service, $0.configHash) })
        let backend = MockBackend(containers: [
            existing("db", hash: hashes["db"] ?? "", status: .stopped),
            existing("web", hash: hashes["web"] ?? "", status: .stopped),
        ])
        let store = ComposeStore(backend: backend)

        let job = store.up(plan)
        await settled(job)

        #expect(job.state == .succeeded)
        #expect(backend.calls.createContainer == 0)
        #expect(backend.calls.start == 2)
    }

    /// Only the service whose settings changed.
    @Test func achangedServiceIsRecreatedAndTheRestAreLeftAlone() async throws {
        let plan = try plan()
        let hashes = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.service, $0.configHash) })
        let backend = MockBackend(containers: [
            existing("db", hash: hashes["db"] ?? ""),
            existing("web", hash: "stale-hash-from-an-older-file"),
        ])
        let store = ComposeStore(backend: backend)

        let job = store.up(plan)
        await settled(job)

        #expect(job.state == .succeeded)
        #expect(backend.calls.createContainer == 1)
        let deleted = backend.invocations.filter { $0.action == "delete" }.map(\.id)
        #expect(deleted == ["shop-web"])
        #expect(job.steps.first { $0.service == "db" }?.status == .reused)
    }

    /// Tearing down a database the user just seeded because a later service had
    /// a typo is worse than a half-started project.
    @Test func afailurePartwayLeavesEarlierServicesRunning() async throws {
        let backend = MockBackend()
        backend.setCreateFailure(forID: "shop-web", .upstream(code: "notFound", message: "no such image"))
        let store = ComposeStore(backend: backend)

        let job = store.up(try plan())
        await settled(job)

        guard case .failed(let service, let error) = job.state else {
            Issue.record("expected a failure, got \(job.state)")
            return
        }
        #expect(service == "web")
        #expect(error.errorDescription?.contains("no such image") == true)
        // The one before it is up and stays up.
        #expect(job.steps.first { $0.service == "db" }?.status == .ready)
        #expect(backend.invocations.contains { $0.id == "shop-db" && $0.action == "start" })
        // Nothing was rolled back.
        #expect(!backend.invocations.contains { $0.action == "delete" && $0.id == "shop-db" })
    }

    /// A cancelled `AsyncThrowingStream` finishes rather than throwing, so
    /// success must never be inferred from a loop ending.
    @Test func cancellationReportsCancelledNeverSuccess() async throws {
        let backend = MockBackend()
        backend.gateLifecycleCalls()
        let store = ComposeStore(backend: backend)

        let job = store.up(try plan())
        await backend.waitForGatedCall()
        job.cancel()
        backend.releaseGate()
        await settled(job)

        #expect(job.state == .cancelled)
    }

    /// Failing deep in the runtime three services later gives an error that
    /// never mentions the port.
    @Test func aportAlreadyTakenIsRefusedBeforeAnythingIsCreated() async throws {
        let backend = MockBackend(containers: [
            .stub(
                id: "someone-elses-app",
                status: .running,
                ports: [.init(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, networkProtocol: "tcp")]
            )
        ])
        let store = ComposeStore(backend: backend)

        let job = store.up(try plan("services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n"))
        await settled(job)

        guard case .failed(_, let error) = job.state else {
            Issue.record("expected a refusal, got \(job.state)")
            return
        }
        #expect(error.errorDescription?.contains("8080") == true)
        #expect(error.errorDescription?.contains("someone-elses-app") == true)
        #expect(backend.calls.createContainer == 0, "nothing may be created once a conflict is known")
    }
}

@MainActor
@Suite struct ComposeDownTests {

    private func backend(project: String = "shop") -> MockBackend {
        MockBackend(containers: [
            .stub(
                id: "\(project)-web", status: .running,
                labels: [
                    ComposeLabels.project: project, ComposeLabels.service: "web",
                    ComposeLabels.dependsOn: "db",
                ]),
            .stub(
                id: "\(project)-db", status: .running,
                labels: [ComposeLabels.project: project, ComposeLabels.service: "db"]),
            .stub(id: "unrelated", status: .running),
        ])
    }

    private func settled(_ job: ComposeJob) async {
        while !job.isFinished { await Task.yield() }
    }

    @Test func stopsAndDeletesInReverseDependencyOrder() async throws {
        let backend = backend()
        let store = ComposeStore(backend: backend)
        await store.refresh()

        let job = store.down(project: "shop")
        await settled(job)

        #expect(job.state == .succeeded)
        let deleted = backend.invocations.filter { $0.action == "delete" }.map(\.id)
        // web depends on db, so web goes first.
        #expect(deleted == ["shop-web", "shop-db"])
    }

    @Test func leavesEverythingElseAlone() async throws {
        let backend = backend()
        let store = ComposeStore(backend: backend)
        await store.refresh()

        let job = store.down(project: "shop")
        await settled(job)

        #expect(!backend.invocations.contains { $0.id == "unrelated" })
        #expect(backend.currentContainers.map(\.id) == ["unrelated"])
    }

    /// The file may have moved or been edited; the containers are the truth.
    @Test func worksFromLabelsWithNoComposeFileInvolved() async throws {
        let backend = backend()
        let store = ComposeStore(backend: backend)
        // Never refreshed, so the store has no cached project — `down` still
        // has to find the containers.
        let job = store.down(project: "shop")
        await settled(job)

        #expect(job.state == .succeeded)
        #expect(backend.invocations.filter { $0.action == "delete" }.count == 2)
    }

    @Test func removesOnlyTheVolumesItIsGiven() async throws {
        let backend = backend()
        let store = ComposeStore(backend: backend)
        await store.refresh()

        let job = store.down(project: "shop", removingVolumes: ["shop_pgdata"])
        await settled(job)

        #expect(backend.invocations.contains { $0.action == "deleteVolume" && $0.id == "shop_pgdata" })
    }
}

@Suite struct ComposeProjectDiscoveryTests {

    /// Projects survive an app restart because they live in labels, not in
    /// anything Dockyard keeps.
    @Test func groupsContainersByTheirProjectLabel() {
        let projects = ComposeProject.discover(in: [
            .stub(id: "shop-web", labels: [ComposeLabels.project: "shop", ComposeLabels.service: "web"]),
            .stub(id: "shop-db", status: .stopped, labels: [ComposeLabels.project: "shop", ComposeLabels.service: "db"]),
            .stub(id: "blog-web", labels: [ComposeLabels.project: "blog", ComposeLabels.service: "web"]),
            .stub(id: "plain"),
        ])

        #expect(projects.map(\.name) == ["blog", "shop"])
        let shop = projects.first { $0.name == "shop" }
        #expect(shop?.services.map(\.service) == ["db", "web"])
        #expect(shop?.summary == "1 of 2 running")
        #expect(shop?.isFullyRunning == false)
    }

    @Test func stopOrderComesFromTheDependsOnLabel() {
        let project = ComposeProject.discover(in: [
            .stub(id: "p-web", labels: [ComposeLabels.project: "p", ComposeLabels.service: "web", ComposeLabels.dependsOn: "api"]),
            .stub(id: "p-api", labels: [ComposeLabels.project: "p", ComposeLabels.service: "api", ComposeLabels.dependsOn: "db"]),
            .stub(id: "p-db", labels: [ComposeLabels.project: "p", ComposeLabels.service: "db"]),
        ])[0]

        #expect(project.stopOrder.map(\.service) == ["web", "api", "db"])
    }

    @Test func aProjectWithNoLabelledContainersIsNotInvented() {
        #expect(ComposeProject.discover(in: [.stub(id: "plain")]).isEmpty)
    }
}
