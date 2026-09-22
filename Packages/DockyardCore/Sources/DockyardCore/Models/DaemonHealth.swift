import Foundation

/// What `container-apiserver` reports about itself when it answers a ping.
public struct DaemonHealth: Sendable, Hashable, Codable {
    /// Raw version string from the server. This is *not* a bare semver: 1.0.0
    /// reports the whole sentence
    /// `"container-apiserver version 1.0.0 (build: release, commit: ee848e3)"`,
    /// because the server sends `ReleaseVersion.singleLine(appName:)` and
    /// upstream's own `container system version` prints it unparsed. Use
    /// `semanticVersion` to compare, `apiServerVersion` only to display.
    public let apiServerVersion: String
    public let apiServerCommit: String
    public let apiServerBuild: String
    public let appName: String
    /// `~/Library/Application Support/com.apple.container`.
    public let appRoot: URL
    /// Where the runtime's binaries and plugins are installed.
    public let installRoot: URL
    /// Directory holding apiserver logs, when the server reports one.
    public let logRoot: URL?

    public init(
        apiServerVersion: String,
        apiServerCommit: String,
        apiServerBuild: String,
        appName: String,
        appRoot: URL,
        installRoot: URL,
        logRoot: URL?
    ) {
        self.apiServerVersion = apiServerVersion
        self.apiServerCommit = apiServerCommit
        self.apiServerBuild = apiServerBuild
        self.appName = appName
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.logRoot = logRoot
    }

    /// The `x.y.z` found in `apiServerVersion`, whether the server sent a bare
    /// version or the full sentence. `nil` if neither shape matches.
    public var semanticVersion: String? {
        guard let match = apiServerVersion.firstMatch(of: /\d+\.\d+\.\d+/) else { return nil }
        return String(match.output)
    }

    /// True when the running server matches the client libraries this app links.
    ///
    /// An unparseable version is treated as a match: the app should not block
    /// the user over a version string it merely failed to read.
    public var matchesLinkedVersion: Bool {
        guard let semanticVersion else { return true }
        return semanticVersion == DockyardCore.linkedContainerVersion
    }

    public var shortCommit: String { String(apiServerCommit.prefix(7)) }
}
