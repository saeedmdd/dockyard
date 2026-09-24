import Foundation
import Observation

/// One `up` or `down`, with a step per service.
///
/// Modelled on `BuildJob`: a long-running thing the user watches, cancels, and
/// reads the output of afterwards.
@MainActor
@Observable
public final class ComposeJob: Identifiable, Sendable {
    public enum Kind: String, Sendable { case up, down }

    public enum State: Sendable, Equatable {
        case running
        case succeeded
        case cancelled
        /// Named so the UI can point at the service that stopped the run.
        case failed(service: String?, error: DockyardError)
    }

    public struct Step: Sendable, Identifiable, Equatable {
        public enum Status: Sendable, Equatable {
            case waiting
            case pulling(PullProgress)
            case creating
            case starting
            case ready
            /// Already correct and already running; nothing was done.
            case reused
            case recreating
            case stopping
            case removed
            case failed(DockyardError)
            case skipped(reason: String)

            public var isTerminal: Bool {
                switch self {
                case .ready, .reused, .removed, .failed, .skipped: true
                default: false
                }
            }
        }

        public let service: String
        public let containerID: String
        public var status: Status = .waiting
        public var startedAt: Date?
        public var finishedAt: Date?

        public var id: String { containerID }
    }

    public let id = UUID()
    public let projectName: String
    public let kind: Kind
    public private(set) var state: State = .running
    public private(set) var steps: [Step]
    public private(set) var output = LogBuffer(capacity: 5_000)
    public let startedAt = Date()
    public private(set) var finishedAt: Date?

    private var task: Task<Void, Never>?

    init(projectName: String, kind: Kind, steps: [Step]) {
        self.projectName = projectName
        self.kind = kind
        self.steps = steps
    }

    public var isFinished: Bool { state != .running }
    public var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    public var completedCount: Int { steps.count(where: { $0.status.isTerminal }) }

    public func cancel() { task?.cancel() }

    func attach(_ task: Task<Void, Never>) { self.task = task }

    func update(_ service: String, _ status: Step.Status) {
        guard let index = steps.firstIndex(where: { $0.service == service }) else { return }
        if steps[index].startedAt == nil { steps[index].startedAt = Date() }
        if status.isTerminal { steps[index].finishedAt = Date() }
        steps[index].status = status
    }

    func log(_ text: String) {
        output.append([text], source: .stdio)
    }

    func finish(_ state: State) {
        self.state = state
        finishedAt = Date()
    }
}

/// Runs compose projects.
@MainActor
@Observable
public final class ComposeStore {
    public private(set) var projects: [ComposeProject] = []
    public private(set) var jobs: [ComposeJob] = []
    public private(set) var lastError: DockyardError?

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public var activeJobs: [ComposeJob] { jobs.filter { !$0.isFinished } }

    public func job(for project: String) -> ComposeJob? {
        jobs.last { $0.projectName == project }
    }

    /// Groups an already-fetched container list. The app polls containers
    /// anyway, so a project list costs nothing extra.
    public func refresh(from containers: [ContainerItem]) {
        projects = ComposeProject.discover(in: containers)
    }

    public func refresh() async {
        do {
            refresh(from: try await backend.listContainers())
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            projects = []
        } catch {
            lastError = DockyardError(mapping: error)
        }
    }

    public func dismiss(_ job: ComposeJob) {
        jobs.removeAll { $0.id == job.id }
    }

    // MARK: - Up

    @discardableResult
    public func up(_ plan: ComposeUpPlan) -> ComposeJob {
        let job = ComposeJob(
            projectName: plan.projectName,
            kind: .up,
            steps: plan.steps.map { .init(service: $0.service, containerID: $0.containerID) }
        )
        jobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await runUp(plan, job: job)
                try Task.checkCancellation()
                job.finish(.succeeded)
            } catch is CancellationError {
                job.log("Cancelled.")
                job.finish(.cancelled)
            } catch let failure as StepFailure {
                job.update(failure.service, .failed(failure.error))
                job.log("\(failure.service): \(failure.error.errorDescription ?? "failed")")
                job.finish(.failed(service: failure.service, error: failure.error))
            } catch {
                let mapped = DockyardError(mapping: error)
                job.log(mapped.errorDescription ?? "Failed.")
                job.finish(.failed(service: nil, error: mapped))
            }
            await refresh()
        }
        job.attach(task)
        return job
    }

    private struct StepFailure: Error {
        let service: String
        let error: DockyardError
    }

    private func runUp(_ plan: ComposeUpPlan, job: ComposeJob) async throws {
        // Checked before anything is created: failing deep in the runtime three
        // services later gives an error that never mentions the port.
        if let conflict = try await portConflict(in: plan) {
            throw StepFailure(
                service: conflict.service,
                error: .upstream(
                    code: "invalidArgument",
                    message: "Port \(conflict.port) is already used by “\(conflict.holder)”. "
                        + "Stop it, or change the port in the compose file."
                )
            )
        }

        let existing = try await backend.listContainers(
            matchingLabels: ComposeLabels.filter(project: plan.projectName)
        )
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for step in plan.steps {
            try Task.checkCancellation()

            if let current = byID[step.containerID] {
                let sameSettings = current.labels[ComposeLabels.configHash] == step.configHash
                if sameSettings, current.status == .running {
                    job.update(step.service, .reused)
                    job.log("\(step.service): already running.")
                    continue
                }
                if sameSettings {
                    job.update(step.service, .starting)
                    try await start(step, job: job)
                    continue
                }
                job.update(step.service, .recreating)
                job.log("\(step.service): settings changed, recreating.")
                do {
                    if current.status == .running {
                        try await backend.stopContainer(id: step.containerID)
                    }
                    try await backend.deleteContainer(id: step.containerID, force: true)
                } catch {
                    throw StepFailure(service: step.service, error: DockyardError(mapping: error))
                }
                byID.removeValue(forKey: step.containerID)
            }

            try Task.checkCancellation()
            job.update(step.service, .creating)
            do {
                for try await update in backend.createContainer(spec: step.spec) {
                    switch update {
                    case .working(let progress): job.update(step.service, .pulling(progress))
                    case .created: job.update(step.service, .creating)
                    }
                }
                // A cancelled stream *finishes* rather than throwing, so success
                // is never inferred from the loop ending.
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw StepFailure(service: step.service, error: DockyardError(mapping: error))
            }
            job.log("\(step.service): created.")
            try await start(step, job: job)
        }
    }

    private func start(_ step: ComposeServicePlan, job: ComposeJob) async throws {
        job.update(step.service, .starting)
        do {
            try await backend.startContainer(id: step.containerID)
        } catch {
            throw StepFailure(service: step.service, error: DockyardError(mapping: error))
        }
        try Task.checkCancellation()
        job.update(step.service, .ready)
        job.log("\(step.service): running.")
    }

    private struct PortConflict {
        let service: String
        let port: String
        let holder: String
    }

    /// A published host port already held by a container outside this project.
    private func portConflict(in plan: ComposeUpPlan) async throws -> PortConflict? {
        let all = try await backend.listContainers()
        let ours = Set(plan.steps.map(\.containerID))
        var taken: [UInt16: String] = [:]
        for container in all where !ours.contains(container.id) && container.status == .running {
            for port in container.ports { taken[port.hostPort] = container.id }
        }
        for step in plan.steps {
            for published in step.spec.publishedPorts {
                guard let mapping = ComposeParser.parsePort(published),
                    let holder = taken[mapping.hostPort]
                else { continue }
                return .init(service: step.service, port: String(mapping.hostPort), holder: holder)
            }
        }
        return nil
    }

    // MARK: - Down

    @discardableResult
    public func down(project name: String, removingVolumes volumes: [String] = []) -> ComposeJob {
        let known = projects.first { $0.name == name }
        let order = known?.stopOrder ?? []
        let job = ComposeJob(
            projectName: name,
            kind: .down,
            steps: order.map { .init(service: $0.service, containerID: $0.containerID) }
        )
        jobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await runDown(name, volumes: volumes, job: job)
                job.finish(.succeeded)
            } catch is CancellationError {
                job.finish(.cancelled)
            } catch {
                let mapped = DockyardError(mapping: error)
                job.log(mapped.errorDescription ?? "Failed.")
                job.finish(.failed(service: nil, error: mapped))
            }
            await refresh()
        }
        job.attach(task)
        return job
    }

    private func runDown(_ name: String, volumes: [String], job: ComposeJob) async throws {
        // From the labels, not from the file: a service deleted from the
        // compose file still has a container, and a project whose file has
        // moved still has to come down.
        let containers = try await backend.listContainers(
            matchingLabels: ComposeLabels.filter(project: name)
        )
        let discovered = ComposeProject.discover(in: containers).first { $0.name == name }
        let order = discovered?.stopOrder ?? []

        for service in order {
            try Task.checkCancellation()
            job.update(service.service, .stopping)
            if service.status == .running {
                do {
                    try await backend.stopContainer(id: service.containerID)
                } catch {
                    // Worth saying, not worth stopping for: the delete below
                    // forces its way through anyway.
                    job.log("\(service.service): could not stop cleanly, deleting anyway.")
                }
            }
            do {
                try await backend.deleteContainer(id: service.containerID, force: true)
                job.update(service.service, .removed)
                job.log("\(service.service): removed.")
            } catch {
                job.update(service.service, .failed(DockyardError(mapping: error)))
                throw error
            }
        }

        for volume in volumes {
            do {
                try await backend.deleteVolume(name: volume)
                job.log("removed volume \(volume).")
            } catch {
                job.log("could not remove volume \(volume): \(DockyardError(mapping: error).shortReason)")
            }
        }
    }
}
