import Foundation

/// A registry this Mac has credentials for.
public struct RegistryLogin: Sendable, Hashable, Codable, Identifiable {
    public let hostname: String
    public let username: String
    public let createdAt: Date
    public let modifiedAt: Date

    public var id: String { hostname }

    public init(hostname: String, username: String, createdAt: Date, modifiedAt: Date) {
        self.hostname = hostname
        self.username = username
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Credentials being entered for a registry.
public struct RegistryCredentials: Sendable, Equatable {
    public var hostname: String = ""
    public var username: String = ""
    public var password: String = ""

    public init() {}

    public var trimmedHostname: String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if trimmedHostname.isEmpty {
            problems.append("Enter the registry, like ghcr.io or docker.io.")
        }
        if trimmedUsername.isEmpty {
            problems.append("Enter your username.")
        }
        if password.isEmpty {
            problems.append("Enter your password or access token.")
        }
        return problems
    }

    public var isValid: Bool { validationProblems.isEmpty }
}

/// How to reach a registry.
///
/// `auto` chooses HTTPS for anything that looks like a real registry, which is
/// right almost always and wrong for a plain-HTTP one on localhost — where it
/// fails with "I/O on closed channel" rather than anything that mentions TLS.
public enum RegistryScheme: String, Sendable, CaseIterable, Identifiable, Codable {
    case auto
    case https
    case http

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .https: "HTTPS"
        case .http: "HTTP (insecure)"
        }
    }
}
