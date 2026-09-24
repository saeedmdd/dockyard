import Foundation

/// One service of a project, as it exists right now.
public struct ComposeProjectService: Sendable, Equatable, Identifiable {
    public let service: String
    public let containerID: String
    public let status: ContainerStatus
    public let configHash: String
    public let dependsOn: [String]
    public let ports: [PortMapping]

    public var id: String { containerID }
    public var isRunning: Bool { status == .running }
}

/// A project, discovered entirely from container labels.
///
/// Deliberately not read from the compose file: the file may have moved, been
/// edited or been deleted, and a project still has to be listable and
/// stoppable. The file path is carried as a label so the UI can offer to reload
/// it, but nothing here depends on it existing.
public struct ComposeProject: Sendable, Equatable, Identifiable {
    public let name: String
    /// Where the file was when the project was last started.
    public let fileURL: URL?
    public let services: [ComposeProjectService]

    public var id: String { name }
    public var runningCount: Int { services.count(where: \.isRunning) }
    public var serviceCount: Int { services.count }
    public var isFullyRunning: Bool { serviceCount > 0 && runningCount == serviceCount }

    public var summary: String { "\(runningCount) of \(serviceCount) running" }

    /// Stop order, taken from the labels rather than the file — the file may be
    /// gone, and a project must still come down cleanly.
    public var stopOrder: [ComposeProjectService] {
        var remaining: [String: Set<String>] = [:]
        for service in services {
            remaining[service.service] = Set(service.dependsOn).intersection(services.map(\.service))
        }
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.value.isEmpty }.keys.sorted()
            guard let next = ready.first else {
                // A cycle cannot happen through `up`, but a hand-edited label
                // could produce one; stopping in name order is still correct,
                // just not optimal.
                ordered.append(contentsOf: remaining.keys.sorted())
                break
            }
            ordered.append(next)
            remaining.removeValue(forKey: next)
            for key in remaining.keys { remaining[key]?.remove(next) }
        }
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0) })
        return ordered.reversed().compactMap { byName[$0] }
    }

    /// Groups whatever containers carry a project label.
    public static func discover(in containers: [ContainerItem]) -> [ComposeProject] {
        var grouped: [String: [ContainerItem]] = [:]
        for container in containers {
            guard let project = container.labels[ComposeLabels.project], !project.isEmpty else { continue }
            grouped[project, default: []].append(container)
        }
        return grouped.map { name, members in
            ComposeProject(
                name: name,
                fileURL: members.compactMap { $0.labels[ComposeLabels.file] }.first.map(URL.init(fileURLWithPath:)),
                services: members.map { container in
                    ComposeProjectService(
                        service: container.labels[ComposeLabels.service] ?? container.id,
                        containerID: container.id,
                        status: container.status,
                        configHash: container.labels[ComposeLabels.configHash] ?? "",
                        dependsOn: (container.labels[ComposeLabels.dependsOn] ?? "")
                            .split(separator: ",").map(String.init),
                        ports: container.ports
                    )
                }
                .sorted { $0.service < $1.service }
            )
        }
        .sorted { $0.name < $1.name }
    }
}
