import Foundation

/// A named volume the runtime manages.
///
/// Volumes outlive the containers that use them, which is the point of them and
/// also the reason deleting one needs care.
public struct VolumeItem: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let driver: String
    public let format: String
    /// Where the runtime keeps it on disk.
    public let source: String
    public let createdAt: Date
    public let labels: [String: String]
    public let options: [String: String]
    /// Declared size, when the volume has one. Not the same as bytes used.
    public let sizeInBytes: UInt64?

    public var id: String { name }

    public init(
        name: String,
        driver: String,
        format: String,
        source: String,
        createdAt: Date,
        labels: [String: String],
        options: [String: String],
        sizeInBytes: UInt64?
    ) {
        self.name = name
        self.driver = driver
        self.format = format
        self.source = source
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
        self.sizeInBytes = sizeInBytes
    }
}

/// What to create.
public struct VolumeSpec: Sendable, Equatable {
    public var name: String = ""
    /// `local` is the only driver the runtime ships, and the field exists so an
    /// added one would not need a new model.
    public var driver: String = "local"
    public var labels: [RunSpec.KeyValue] = []
    public var options: [RunSpec.KeyValue] = []

    public init() {}

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Problems worth stopping for before asking the runtime.
    public var validationProblems: [String] {
        var problems: [String] = []
        if trimmedName.isEmpty {
            problems.append("Give the volume a name.")
        } else if !Self.isValidName(trimmedName) {
            problems.append(
                "“\(trimmedName)” isn’t a valid name. Use letters, digits, dots, hyphens and underscores, starting with a letter or digit."
            )
        }
        return problems
    }

    public var isValid: Bool { validationProblems.isEmpty }

    /// The same rule the runtime applies to entity names.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
    }
}
