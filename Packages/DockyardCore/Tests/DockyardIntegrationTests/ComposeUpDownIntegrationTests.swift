import Foundation
import Testing

@testable import DockyardCore

/// `up` and `down` against the real runtime.
///
/// The project name is the fixture's own prefix, so every container is
/// `dockyard-it-xxxxxxxx-<service>` and the fixture's existing prefix sweep
/// cleans them up with no change to it — including when a test fails partway.
@MainActor
@Suite(.enabled(if: IntegrationGate.isEnabled), .serialized)
struct ComposeUpDownIntegrationTests {

    private func composeFile(_ yaml: String, in fixture: IntegrationFixture) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(fixture.prefix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func plan(_ fixture: IntegrationFixture, _ yaml: String) async throws -> ComposeUpPlan {
        let file = try composeFile(yaml, in: fixture)
        let (spec, diagnostics) = ComposeLoader(processEnvironment: [:]).load(
            fileURL: file, projectName: fixture.prefix
        )
        let project = try #require(spec, "diagnostics: \(diagnostics.map(\.display))")
        let domain = try await fixture.backend.dnsDomain()
        return try ComposePlanner.plan(project, dnsDomain: domain).get()
    }

    private func settled(_ job: ComposeJob) async {
        while !job.isFinished { await Task.yield() }
    }

    private var twoServices: String {
        """
        services:
          first:
            image: docker.io/library/alpine:3.20
            command: sleep 120
          second:
            image: docker.io/library/alpine:3.20
            command: sleep 120
            depends_on: [first]
        """
    }

    @Test func upBringsAProjectUpAndDownTakesItAwayAgain() async throws {
        try await withMainActorFixture { fixture in
            try await fixture.ensureTestImage()
            let store = ComposeStore(backend: fixture.backend)
            let plan = try await plan(fixture, twoServices)

            let up = store.up(plan)
            await settled(up)
            #expect(up.state == .succeeded, "steps: \(up.steps.map { "\($0.service)=\($0.status)" })")

            let running = try await fixture.backend.listContainers(
                matchingLabels: ComposeLabels.filter(project: fixture.prefix)
            )
            #expect(running.count == 2)
            #expect(running.allSatisfy { $0.status == .running })
            #expect(running.map(\.id).sorted() == [fixture.name("first"), fixture.name("second")].sorted())

            await store.refresh()
            let project = try #require(store.projects.first { $0.name == fixture.prefix })
            #expect(project.isFullyRunning)

            let down = store.down(project: fixture.prefix)
            await settled(down)
            #expect(down.state == .succeeded)

            let after = try await fixture.backend.listContainers(
                matchingLabels: ComposeLabels.filter(project: fixture.prefix)
            )
            #expect(after.isEmpty)
        }
    }

    /// The whole point of the config hash, proven against the daemon rather
    /// than a mock: an unchanged project must not be rebuilt.
    @Test func asecondUpReusesEverythingAndRecreatesNothing() async throws {
        try await withMainActorFixture { fixture in
            try await fixture.ensureTestImage()
            let store = ComposeStore(backend: fixture.backend)
            let plan = try await plan(fixture, twoServices)

            await settled(store.up(plan))
            let firstCreatedAt = try await fixture.backend
                .listContainers(matchingLabels: ComposeLabels.filter(project: fixture.prefix))
                .map(\.createdAt)

            let second = store.up(plan)
            await settled(second)

            #expect(second.state == .succeeded)
            #expect(second.steps.allSatisfy { $0.status == .reused }, "nothing should have been touched")
            let secondCreatedAt = try await fixture.backend
                .listContainers(matchingLabels: ComposeLabels.filter(project: fixture.prefix))
                .map(\.createdAt)
            // Same containers, not replacements that happen to look alike.
            #expect(firstCreatedAt == secondCreatedAt)
        }
    }

    @Test func achangedSettingRecreatesOnlyThatService() async throws {
        try await withMainActorFixture { fixture in
            try await fixture.ensureTestImage()
            let store = ComposeStore(backend: fixture.backend)

            await settled(store.up(try await plan(fixture, twoServices)))
            let before = try await fixture.backend
                .listContainers(matchingLabels: ComposeLabels.filter(project: fixture.prefix))
            let firstCreatedAt = before.first { $0.id == fixture.name("first") }?.createdAt

            // Only `second` changes.
            let edited = twoServices.replacingOccurrences(
                of: "    command: sleep 120\n    depends_on: [first]",
                with: "    command: sleep 121\n    depends_on: [first]"
            )
            let job = store.up(try await plan(fixture, edited))
            await settled(job)

            #expect(job.state == .succeeded)
            #expect(job.steps.first { $0.service == "first" }?.status == .reused)
            let after = try await fixture.backend
                .listContainers(matchingLabels: ComposeLabels.filter(project: fixture.prefix))
            #expect(after.first { $0.id == fixture.name("first") }?.createdAt == firstCreatedAt)
        }
    }

    /// `down` reads the containers, not the file, so it still works when the
    /// file has been deleted underneath it.
    @Test func downWorksAfterTheComposeFileIsGone() async throws {
        try await withMainActorFixture { fixture in
            try await fixture.ensureTestImage()
            let store = ComposeStore(backend: fixture.backend)
            let plan = try await plan(fixture, twoServices)
            await settled(store.up(plan))

            try FileManager.default.removeItem(at: plan.fileURL)

            let down = store.down(project: fixture.prefix)
            await settled(down)

            #expect(down.state == .succeeded)
            let after = try await fixture.backend
                .listContainers(matchingLabels: ComposeLabels.filter(project: fixture.prefix))
            #expect(after.isEmpty)
        }
    }

    /// Everything else on the machine has to be untouched — the containers the
    /// developer is actually working with included.
    @Test func neitherUpNorDownTouchesAnythingOutsideTheProject() async throws {
        try await withMainActorFixture { fixture in
            try await fixture.ensureTestImage()
            let bystander = try await fixture.create(fixture.sleeperSpec("bystander"))
            let store = ComposeStore(backend: fixture.backend)

            await settled(store.up(try await plan(fixture, twoServices)))
            await settled(store.down(project: fixture.prefix))

            let remaining = try await fixture.backend.listContainers().map(\.id)
            #expect(remaining.contains(bystander))
        }
    }
}
