import Foundation

/// One row in the images list.
///
/// Size is intentionally absent: computing it costs an index fetch plus a
/// manifest fetch per image, which upstream's own CLI calls "the more expensive
/// per-image manifest resolution" and skips in quiet mode. Sizes are fetched on
/// demand through `ContainerBackend.imageSize(reference:)`.
public struct ImageItem: Sendable, Identifiable, Hashable, Codable {
    /// Fully normalized reference, e.g. `docker.io/library/alpine:3.20`.
    public let reference: String
    /// Reference as the CLI displays it, e.g. `alpine:3.20`.
    public let displayReference: String
    public let digest: String
    public let mediaType: String
    /// True for images the runtime manages itself (the BuildKit builder and the
    /// VM init image). Hidden in the UI by default, as in `container image list`.
    public let isInfrastructure: Bool

    public var id: String { reference }

    /// `alpine` from `docker.io/library/alpine:3.20`.
    public var repository: String {
        let withoutTag = Self.splitTag(displayReference).repository
        return withoutTag
    }

    /// `3.20` from `docker.io/library/alpine:3.20`, `nil` when untagged.
    public var tag: String? {
        Self.splitTag(displayReference).tag
    }

    /// First 12 characters after the algorithm prefix, as shown in list rows.
    public var shortDigest: String {
        guard let value = digest.split(separator: ":").last else { return digest }
        return String(value.prefix(12))
    }

    public init(
        reference: String,
        displayReference: String,
        digest: String,
        mediaType: String,
        isInfrastructure: Bool
    ) {
        self.reference = reference
        self.displayReference = displayReference
        self.digest = digest
        self.mediaType = mediaType
        self.isInfrastructure = isInfrastructure
    }

    /// Splits a reference into repository and tag. A colon only introduces a tag
    /// when it appears after the last `/`, otherwise it is a registry port
    /// (`localhost:5000/app`).
    static func splitTag(_ reference: String) -> (repository: String, tag: String?) {
        guard let colon = reference.lastIndex(of: ":") else { return (reference, nil) }
        let afterColon = reference[reference.index(after: colon)...]
        if afterColon.contains("/") { return (reference, nil) }
        return (String(reference[..<colon]), String(afterColon))
    }
}
