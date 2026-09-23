import Foundation

/// How much space one kind of resource is taking.
public struct ResourceUsage: Sendable, Hashable, Codable {
    public let total: Int
    /// How many are in use. The rest are candidates for reclaiming.
    public let active: Int
    public let sizeInBytes: UInt64
    /// What could be freed, as the runtime calculates it.
    public let reclaimableBytes: UInt64

    public var idleCount: Int { max(0, total - active) }

    public var sizeLabel: String { DiskUsage.label(sizeInBytes) }
    public var reclaimableLabel: String { DiskUsage.label(reclaimableBytes) }

    /// Share of this resource's space that could be freed, for a bar.
    public var reclaimableFraction: Double {
        guard sizeInBytes > 0 else { return 0 }
        return min(1, Double(reclaimableBytes) / Double(sizeInBytes))
    }

    public init(total: Int, active: Int, sizeInBytes: UInt64, reclaimableBytes: UInt64) {
        self.total = total
        self.active = active
        self.sizeInBytes = sizeInBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

/// What `container system df` reports.
public struct DiskUsage: Sendable, Hashable, Codable {
    public let images: ResourceUsage
    public let containers: ResourceUsage
    public let volumes: ResourceUsage

    public var totalBytes: UInt64 {
        images.sizeInBytes + containers.sizeInBytes + volumes.sizeInBytes
    }

    public var totalReclaimableBytes: UInt64 {
        images.reclaimableBytes + containers.reclaimableBytes + volumes.reclaimableBytes
    }

    public var totalLabel: String { Self.label(totalBytes) }
    public var totalReclaimableLabel: String { Self.label(totalReclaimableBytes) }

    /// Every byte count on the System panel goes through here.
    ///
    /// `spellsOutZero` is on by default and renders an empty store as "Zero kB",
    /// which reads like a unit conversion went wrong. It has been reintroduced
    /// by hand three times in this app, so the formatting lives with the model
    /// rather than at each call site.
    public static func label(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    public init(images: ResourceUsage, containers: ResourceUsage, volumes: ResourceUsage) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
    }
}

/// Which resources a prune sweeps.
public enum PruneTarget: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case containers
    case images
    case volumes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        }
    }

    /// What the button offers to do, in the user's terms.
    public var actionTitle: String {
        switch self {
        case .containers: "Remove Stopped…"
        case .images: "Remove Unused…"
        case .volumes: "Remove Unused…"
        }
    }

    /// The sentence in the confirmation. Each says what is *kept*, because that
    /// is the thing a user is afraid of losing.
    public var confirmationMessage: String {
        switch self {
        case .containers:
            "Every stopped container is deleted, along with its writable layer. Running containers are untouched."
        case .images:
            "Images no container refers to are deleted. Images in use, and the ones the runtime needs itself, are kept."
        case .volumes:
            "Volumes no container refers to are deleted, with everything stored in them. This cannot be undone."
        }
    }
}

/// What a prune actually did.
public struct PruneResult: Sendable, Hashable, Codable {
    public let target: PruneTarget
    public let removedCount: Int
    public let reclaimedBytes: UInt64

    /// What could not be removed, and why, so a partial sweep is explainable.
    public let failures: [String]

    public init(
        target: PruneTarget,
        removedCount: Int,
        reclaimedBytes: UInt64,
        failures: [String] = []
    ) {
        self.target = target
        self.removedCount = removedCount
        self.reclaimedBytes = reclaimedBytes
        self.failures = failures
    }

    public var failedCount: Int { failures.count }

    public var summary: String {
        guard removedCount > 0 || failedCount > 0 else {
            return "Nothing to remove — no unused \(target.title.lowercased())"
        }
        var parts = ["Removed \(removedCount) \(removedCount == 1 ? singular : target.title.lowercased())"]
        if reclaimedBytes > 0 {
            parts.append("reclaimed \(DiskUsage.label(reclaimedBytes))")
        } else {
            // Layers shared with something still in use are not freed, and
            // saying "reclaimed 0 bytes" invites the question why.
            parts.append("no space reclaimed — what remains is still in use")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) could not be removed")
        }
        return parts.joined(separator: ", ")
    }

    private var singular: String {
        switch target {
        case .containers: "container"
        case .images: "image"
        case .volumes: "volume"
        }
    }
}

/// The kernel the runtime boots containers with.
public struct KernelInfo: Sendable, Hashable, Codable {
    public let path: String
    public let architecture: String
    public let os: String
    /// The arguments it boots with, in the order the runtime passes them.
    public let arguments: [String]

    public init(path: String, architecture: String, os: String, arguments: [String]) {
        self.path = path
        self.architecture = architecture
        self.os = os
        self.arguments = arguments
    }

    public var platformDescription: String { "\(os)/\(architecture)" }

    /// The file name alone, which is what identifies a kernel at a glance.
    public var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
