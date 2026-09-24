import CryptoKit
import Foundation

/// One service, ready to create.
public struct ComposeServicePlan: Sendable, Equatable, Identifiable {
    public let service: String
    /// `<project>-<service>`.
    public let containerID: String
    public let spec: RunSpec
    public let dependsOn: [String]
    /// Digest of everything that affects the container, so `up` can tell
    /// "already correct" from "needs recreating".
    public let configHash: String

    public var id: String { containerID }
}

/// Everything `up` needs, decided without touching the daemon.
public struct ComposeUpPlan: Sendable, Equatable {
    public let projectName: String
    public let fileURL: URL
    /// In start order.
    public let steps: [ComposeServicePlan]
    public let rewrites: [HostnameRewrite]
    public let candidates: [HostnameCandidate]
    public let diagnostics: [ComposeDiagnostic]
    /// Volumes the project owns and `down --volumes` may remove. Excludes
    /// anything declared `external: true`.
    public let ownedVolumes: [String]

    public var stopOrder: [ComposeServicePlan] { steps.reversed() }
}

public enum ComposePlanner {

    public enum PlanError: Error, Sendable, Equatable {
        case graph(ComposeGraph.Problem)
        case invalidName(String, reason: String)

        public var message: String {
            switch self {
            case .graph(let problem): problem.message
            case .invalidName(_, let reason): reason
            }
        }
    }

    /// A DNS label may be 63 characters. `<project>-<service>` plus the domain
    /// becomes one, and silently exceeding it produces a name nothing resolves
    /// — which looks like a networking bug rather than a naming one.
    public static let maximumLabelLength = 63

    public static func plan(
        _ spec: ComposeProjectSpec,
        dnsDomain: String?
    ) -> Result<ComposeUpPlan, PlanError> {
        var diagnostics: [ComposeDiagnostic] = []

        let project = ComposeLoader.sanitise(spec.name)
        guard EntityName.isValid(project) else {
            return .failure(
                .invalidName(
                    project,
                    reason: "“\(spec.name)” does not make a usable project name. Use letters, numbers, "
                        + "dots, dashes or underscores, starting with a letter or number."
                )
            )
        }

        let order: [String]
        switch ComposeGraph.startOrder(spec.services) {
        case .success(let names): order = names
        case .failure(let problem): return .failure(.graph(problem))
        }

        // Without a domain, containers cannot resolve each other at all, so
        // rewriting a name to something equally unresolvable would only hide
        // the real problem.
        if dnsDomain == nil {
            diagnostics.append(
                .warning(
                    "",
                    "No DNS domain is configured, so containers in this project cannot reach each "
                        + "other by name. Set one up from the project screen before starting."
                )
            )
        }

        func resolvedName(_ service: String) -> String {
            let container = "\(project)-\(service)"
            return dnsDomain.map { "\(container).\($0)" } ?? container
        }

        let external = Set(spec.declaredVolumes.filter(\.isExternal).map(\.name))
        var ownedVolumes: Set<String> = []
        var rewrites: [HostnameRewrite] = []
        var candidates: [HostnameCandidate] = []
        var steps: [ComposeServicePlan] = []

        for name in order {
            guard let service = spec.service(named: name) else { continue }
            let containerID = "\(project)-\(name)"

            guard EntityName.isValid(containerID) else {
                return .failure(
                    .invalidName(containerID, reason: "“\(containerID)” is not a usable container name.")
                )
            }
            let fqdnLength = containerID.count + (dnsDomain.map { $0.count + 1 } ?? 0)
            guard fqdnLength <= maximumLabelLength else {
                return .failure(
                    .invalidName(
                        containerID,
                        reason: "“\(containerID)” plus the DNS domain is \(fqdnLength) characters, over "
                            + "the \(maximumLabelLength) a name may have. Shorten the project or the "
                            + "service name."
                    )
                )
            }

            var environment = service.environment
            if service.rewriteHostnames, dnsDomain != nil {
                let result = ComposeHostnames.rewrite(
                    environment: environment,
                    serviceNames: spec.serviceNames,
                    service: name,
                    resolvedName: resolvedName
                )
                environment = result.environment
                rewrites.append(contentsOf: result.rewrites)
                candidates.append(contentsOf: result.candidates)
            }

            var run = RunSpec(image: service.image)
            run.name = containerID
            run.command = service.command
            run.entrypoint = service.entrypoint
            run.environment = environment
            run.workingDirectory = service.workingDirectory
            run.user = service.user
            run.platform = service.platform
            run.publishedPorts = service.ports.map(\.published)
            run.allocateTerminal = service.allocateTerminal
            run.keepStdinOpen = service.keepStdinOpen
            run.useInit = service.useInit
            run.readOnlyRootFilesystem = service.readOnlyRootFilesystem
            run.tmpfs = service.tmpfs
            run.addedCapabilities = service.addedCapabilities
            run.droppedCapabilities = service.droppedCapabilities
            run.memory = service.memory
            run.cpus = service.cpus
            run.shmSize = service.shmSize

            // Empty, always: the runtime then attaches the built-in `default`
            // network, the only one where containers resolve each other by name.
            run.networks = []
            // A container that deletes itself breaks `down`, status and the
            // supervisor, whatever the compose file asked for.
            run.removeWhenStopped = false
            // `up` starts explicitly, so create and start failures land on
            // different steps and are attributable.
            run.startImmediately = false

            run.volumes = service.volumes.map { mount in
                switch mount.kind {
                case .anonymous:
                    return mount.destination
                case .bind:
                    let source = ComposeLoader.resolve(mount.source, against: spec.directory).path
                    return "\(source):\(mount.destination)\(mount.readOnly ? ":ro" : "")"
                case .named:
                    // Namespaced like the containers, so two projects each with
                    // a `data` volume can coexist.
                    let volume = external.contains(mount.source) ? mount.source : "\(project)_\(mount.source)"
                    if !external.contains(mount.source) { ownedVolumes.insert(volume) }
                    return "\(volume):\(mount.destination)\(mount.readOnly ? ":ro" : "")"
                }
            }

            let hash = configHash(for: run, restart: service.restart)
            run.labels =
                service.labels
                + ComposeLabels.labels(
                    project: project,
                    service: name,
                    file: spec.fileURL,
                    configHash: hash,
                    dependsOn: service.dependsOn,
                    restart: service.restart.labelValue
                ).map { RunSpec.KeyValue(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }

            steps.append(
                .init(
                    service: name,
                    containerID: containerID,
                    spec: run,
                    dependsOn: service.dependsOn,
                    configHash: hash
                )
            )
        }

        return .success(
            ComposeUpPlan(
                projectName: project,
                fileURL: spec.fileURL,
                steps: steps,
                rewrites: rewrites,
                candidates: candidates,
                diagnostics: diagnostics,
                ownedVolumes: ownedVolumes.sorted()
            )
        )
    }

    /// A digest of everything that affects the container.
    ///
    /// Built from an explicit canonical projection rather than by encoding the
    /// `RunSpec`. `RunSpec.KeyValue.id` is a fresh `UUID` and is `Codable`, so
    /// `JSONEncoder().encode(spec)` produces a different digest on every run —
    /// and `up` would then delete and recreate every container every time,
    /// losing whatever state lived inside them.
    ///
    /// Labels are excluded because one of them *is* this hash.
    static func configHash(for spec: RunSpec, restart: ComposeRestartPolicy) -> String {
        var lines: [String] = [
            "image=\(spec.image)",
            "command=\(spec.command)",
            "entrypoint=\(spec.entrypoint)",
            "workdir=\(spec.workingDirectory)",
            "user=\(spec.user)",
            "platform=\(spec.platform)",
            "cpus=\(spec.cpus)",
            "memory=\(spec.memory)",
            "shm=\(spec.shmSize)",
            "init=\(spec.useInit)",
            "readonly=\(spec.readOnlyRootFilesystem)",
            "tty=\(spec.allocateTerminal)",
            "stdin=\(spec.keepStdinOpen)",
            // Part of the container's labels, so a change to it has to recreate
            // the container or the label goes stale.
            "restart=\(restart.labelValue)",
        ]
        lines += spec.environment.map { "env=\($0.key)=\($0.value)" }.sorted()
        lines += spec.publishedPorts.map { "port=\($0)" }.sorted()
        lines += spec.volumes.map { "volume=\($0)" }.sorted()
        lines += spec.tmpfs.map { "tmpfs=\($0)" }.sorted()
        lines += spec.addedCapabilities.map { "cap+=\($0)" }.sorted()
        lines += spec.droppedCapabilities.map { "cap-=\($0)" }.sorted()

        let canonical = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
