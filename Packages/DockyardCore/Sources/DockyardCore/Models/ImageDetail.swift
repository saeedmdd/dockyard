import Foundation

/// One platform's build of an image.
///
/// An image reference usually resolves to several of these — `linux/arm64`,
/// `linux/amd64`, and often a handful more — each with its own digest, size and
/// configuration.
public struct ImageVariant: Sendable, Hashable, Codable, Identifiable {
    public let platform: String
    public let digest: String
    public let sizeBytes: Int64

    /// What the image runs when nothing overrides it.
    public let entrypoint: [String]
    public let command: [String]
    public let workingDirectory: String?
    public let user: String?
    public let environment: [String: String]
    public let labels: [String: String]
    /// The signal the image asks to be stopped with, when it specifies one.
    ///
    /// Exposed ports are deliberately absent: `ImageConfig` in containerization
    /// 0.33.3 models User, Env, Entrypoint, Cmd, WorkingDir, Labels and
    /// StopSignal only — there is no ExposedPorts field to read.
    public let stopSignal: String?

    /// The platform an attestation manifest reports. Not a real build.
    public static let attestationPlatform = "unknown/unknown"

    public var id: String { platform }

    public var shortDigest: String {
        guard let value = digest.split(separator: ":").last else { return digest }
        return String(value.prefix(12))
    }

    /// True for the platform this Mac runs natively.
    public var isNative: Bool {
        platform.hasPrefix("linux/arm64")
    }

    public init(
        platform: String,
        digest: String,
        sizeBytes: Int64,
        entrypoint: [String],
        command: [String],
        workingDirectory: String?,
        user: String?,
        environment: [String: String],
        labels: [String: String],
        stopSignal: String?
    ) {
        self.platform = platform
        self.digest = digest
        self.sizeBytes = sizeBytes
        self.entrypoint = entrypoint
        self.command = command
        self.workingDirectory = workingDirectory
        self.user = user
        self.environment = environment
        self.labels = labels
        self.stopSignal = stopSignal
    }
}

/// Everything the image detail pane shows.
public struct ImageDetail: Sendable, Hashable, Codable, Identifiable {
    public let reference: String
    public let displayReference: String
    public let digest: String
    public let mediaType: String
    public let createdAt: Date?
    public let variants: [ImageVariant]

    public var id: String { reference }

    /// Total across every platform, which is what the image costs on disk.
    public var totalSizeBytes: Int64 {
        variants.reduce(0) { $0 + $1.sizeBytes }
    }

    /// The variant this Mac would run, falling back to the first.
    public var preferredVariant: ImageVariant? {
        variants.first(where: \.isNative) ?? variants.first
    }

    public init(
        reference: String,
        displayReference: String,
        digest: String,
        mediaType: String,
        createdAt: Date?,
        variants: [ImageVariant]
    ) {
        self.reference = reference
        self.displayReference = displayReference
        self.digest = digest
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.variants = variants
    }
}

/// What happened when an image was deleted.
public struct ImageDeletionResult: Sendable, Equatable {
    public let reference: String
    /// Bytes freed by garbage-collecting blobs no image references any more.
    ///
    /// Deleting an image only removes the reference; the layers survive until
    /// collected, and layers shared with another image are not freed at all.
    /// Reporting the real figure avoids implying a 900 MB image freed 900 MB.
    public let reclaimedBytes: UInt64

    public init(reference: String, reclaimedBytes: UInt64) {
        self.reference = reference
        self.reclaimedBytes = reclaimedBytes
    }
}
