import Foundation

/// Where the machine stands on name resolution between containers.
public enum ComposeDNSState: Sendable, Equatable {
    /// No domain anywhere. Containers cannot reach each other by name.
    case notConfigured
    /// Written to the config file, but the daemon has not re-read it. The
    /// daemon only copies the configuration on start, so this needs a restart.
    case restartPending(domain: String)
    /// Containers can resolve each other, but this Mac cannot resolve them.
    /// Only matters for reaching a container from the host.
    case hostResolverMissing(domain: String)
    case ready(domain: String)

    /// Whether containers in a project can find each other. The host resolver
    /// is a convenience on top and deliberately does not count.
    public var containersCanResolveEachOther: Bool {
        switch self {
        case .ready, .hostResolverMissing: true
        case .notConfigured, .restartPending: false
        }
    }

    public var domain: String? {
        switch self {
        case .notConfigured: nil
        case .restartPending(let domain), .hostResolverMissing(let domain), .ready(let domain): domain
        }
    }

    public var summary: String {
        switch self {
        case .notConfigured:
            "Containers cannot reach each other by name yet."
        case .restartPending(let domain):
            "“\(domain)” is configured but the container system has not picked it up — restart it."
        case .hostResolverMissing(let domain):
            "Containers can reach each other. This Mac cannot resolve `.\(domain)` names itself."
        case .ready(let domain):
            "Ready. Containers resolve each other as `<name>.\(domain)`."
        }
    }
}

/// Reads and writes the DNS prerequisite.
public enum ComposeDNSSetup {
    /// RFC 6761 reserves `.test` for exactly this, so it can never collide with
    /// something real.
    public static let defaultDomain = "test"

    public static var userConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/container/config.toml")
    }

    // MARK: - State

    /// Pure, so the whole state machine is testable without touching `/etc`,
    /// the daemon, or the user's home directory.
    public static func state(
        effectiveDomain: String?,
        resolverDomains: [String],
        onDiskDomain: String?
    ) -> ComposeDNSState {
        if let effective = effectiveDomain, !effective.isEmpty {
            // The resolver files are named for the domain, sometimes with a
            // trailing dot; compare on the bare label.
            let known = resolverDomains.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return known.contains(effective) ? .ready(domain: effective) : .hostResolverMissing(domain: effective)
        }
        if let onDisk = onDiskDomain, !onDisk.isEmpty {
            return .restartPending(domain: onDisk)
        }
        return .notConfigured
    }

    /// The domain written in the user's config file, whatever the daemon is
    /// currently using.
    public static func onDiskDomain(at url: URL? = nil) -> String? {
        let url = url ?? userConfigURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return domain(inTOML: text)
    }

    /// Finds `domain` inside the `[dns]` table.
    ///
    /// A deliberately small reader rather than a TOML dependency: this looks for
    /// one key in one table, and the write path below never needs to re-emit a
    /// document.
    static func domain(inTOML text: String) -> String? {
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section == "dns" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "domain" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func hasDNSTable(inTOML text: String) -> Bool {
        text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "[dns]"
        }
    }

    // MARK: - Validation

    /// Nil when the domain is usable, otherwise why not.
    public static func validate(domain: String) -> String? {
        if domain.isEmpty { return "Pick a domain, for example “\(defaultDomain)”." }
        if domain.contains(".") {
            return "Use a single label with no dots, for example “\(defaultDomain)”."
        }
        if domain == "local" {
            // Bonjour owns `.local`; taking it over breaks name resolution for
            // printers, AirPlay and every other device on the network.
            return "“local” is used by Bonjour for devices on your network. Pick another, "
                + "for example “\(defaultDomain)”."
        }
        guard domain.range(of: "^[a-z][a-z0-9-]{0,30}$", options: .regularExpression) != nil else {
            return "Use lowercase letters, numbers and dashes, starting with a letter."
        }
        return nil
    }

    // MARK: - Writing the config

    /// What writing the domain would do, decided before anything is touched so
    /// the UI can show it and the user can refuse.
    public enum ConfigEdit: Sendable, Equatable {
        case create(url: URL, contents: String)
        case append(url: URL, addition: String, backup: URL)
        /// The file already has a `[dns]` table. Machine-editing somebody's
        /// hand-written configuration is not worth the one branch it saves.
        case refuse(url: URL, reason: String)

        public var isRefusal: Bool { if case .refuse = self { true } else { false } }
    }

    public static func plannedEdit(domain: String, at url: URL? = nil) -> ConfigEdit {
        let url = url ?? userConfigURL
        let table = "[dns]\ndomain = \"\(domain)\"\n"

        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return .create(url: url, contents: table)
        }
        guard !hasDNSTable(inTOML: existing) else {
            return .refuse(
                url: url,
                reason: "Your configuration already has a [dns] section. Dockyard will not edit it — "
                    + "set `domain = \"\(domain)\"` there yourself."
            )
        }
        // A new table header at the end of the file is the only TOML edit that
        // provably cannot change the meaning of an existing table, which is why
        // it is done this way rather than by round-tripping a parser.
        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        return .append(
            url: url,
            addition: separator + table,
            backup: url.appendingPathExtension("dockyard-backup")
        )
    }

    @discardableResult
    public static func apply(_ edit: ConfigEdit) throws -> URL? {
        switch edit {
        case .refuse(_, let reason):
            throw DockyardError.other(reason)
        case .create(let url, let contents):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return nil
        case .append(let url, let addition, let backup):
            let existing = try String(contentsOf: url, encoding: .utf8)
            try existing.write(to: backup, atomically: true, encoding: .utf8)
            try (existing + addition).write(to: url, atomically: true, encoding: .utf8)
            return backup
        }
    }

    // MARK: - The privileged step

    /// `container system dns create <domain>`, quoted for a shell.
    ///
    /// Shown to the user verbatim before anything is run: the macOS
    /// authorization dialog says only that Dockyard wants to make changes, so
    /// the app has to be the one that says what.
    public static func privilegedCommand(cliPath: String, domain: String) -> String {
        "\(shellQuoted(cliPath)) system dns create \(shellQuoted(domain))"
    }

    /// Wraps a command for `NSAppleScript`.
    ///
    /// Two traps, both recorded here because neither is visible at the call
    /// site: `NSAppleScript.executeAndReturnError` is not thread-safe and must
    /// run on the main thread, and it **blocks** until the user answers — so
    /// the caller needs a waiting state before it starts.
    public static func appleScript(forPrivileged command: String) -> String {
        "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
