import Foundation

/// One value Dockyard changed, kept so the user can see exactly what happened.
public struct HostnameRewrite: Sendable, Hashable, Identifiable, Codable {
    public enum Rule: String, Sendable, Codable {
        /// The host part of a URL.
        case urlAuthority
        /// A whole value that was a bare host, or `host:port`.
        case hostPort
    }

    public let service: String
    public let key: String
    public let before: String
    public let after: String
    public let rule: Rule

    public var id: String { "\(service)|\(key)" }

    /// How it reads in the log and in the Rewrites pane.
    public var display: String { "\(service).\(key): \(before) → \(after)" }
}

/// A value that names a service but was left alone, because its key gave no
/// sign of being a hostname.
///
/// Reported rather than rewritten: `POSTGRES_USER=db` and `BACKEND=api` are
/// indistinguishable by value, and quietly rewriting the first is worse than
/// quietly missing the second. Surfacing both lets the user settle it.
public struct HostnameCandidate: Sendable, Hashable, Identifiable, Codable {
    public let service: String
    public let key: String
    public let value: String
    public let matchedService: String

    public var id: String { "\(service)|\(key)" }

    public var display: String {
        "\(service).\(key) = \(value) — matches the service “\(matchedService)” but the key does not "
            + "look like a hostname, so it was left as written."
    }
}

/// Rewrites service names in environment values to the names that actually
/// resolve on this runtime.
///
/// Deliberately conservative. Two narrow tiers and nothing else; there is no
/// free-text substitution anywhere, so `command`, mount paths and labels are
/// never touched.
public enum ComposeHostnames {

    public struct Result: Sendable, Equatable {
        public var environment: [RunSpec.KeyValue]
        public var rewrites: [HostnameRewrite]
        public var candidates: [HostnameCandidate]
    }

    /// Key fragments that mark a value as a hostname. Checked case-insensitively.
    static let hostKeyMarkers = [
        "HOST", "ADDR", "ADDRESS", "SERVER", "ENDPOINT", "URL", "URI", "BROKER",
        "NODE", "PEER", "UPSTREAM", "TARGET", "PROXY", "DSN", "CONN", "SVC", "SERVICE",
    ]

    /// Segments that mean the value is something other than a host, whatever it
    /// looks like. Matched as a **whole segment**, not as a substring: `NAME`
    /// would otherwise reject `HOSTNAME`, and `KEY` would reject `HOSTKEY`.
    static let nonHostKeySegments: Set<String> = [
        "USER", "PASS", "PASSWORD", "SECRET", "TOKEN", "KEY", "NAME", "DB", "DATABASE",
        "SCHEMA", "PATH", "HOME", "SHELL", "TERM", "LANG", "TZ", "PWD", "LOGNAME",
    ]

    /// What a key says about its value.
    enum KeyConfidence {
        /// The key names a host: rewrite it.
        case host
        /// The key names something else: leave it, and do not even mention it.
        case notHost
        /// The key gives no signal either way. If the value happens to name a
        /// service, that is worth telling the user about — it is the only case
        /// where they might need to act.
        case ambiguous
    }

    static func confidence(for key: String) -> KeyConfidence {
        let last = key.uppercased().split(separator: "_").last.map(String.init) ?? key.uppercased()
        if nonHostKeySegments.contains(last) { return .notHost }
        return hostKeyMarkers.contains(where: last.contains) ? .host : .ambiguous
    }

    /// True when the key suggests its value is a host.
    ///
    /// The **last** underscore-separated segment decides, because that is where
    /// the meaning of a key lives: `DB_HOST` is a host, `DB_USER` is not, and
    /// both start with `DB`. Testing the whole key for a deny marker instead
    /// rejects `DB_HOST`, `DATABASE_URL` and `POSTGRES_HOST` — the commonest
    /// hostname keys there are.
    static func keyLooksLikeAHost(_ key: String) -> Bool {
        confidence(for: key) == .host
    }

    public static func rewrite(
        environment: [RunSpec.KeyValue],
        serviceNames: Set<String>,
        service: String,
        resolvedName: (String) -> String
    ) -> Result {
        var out: [RunSpec.KeyValue] = []
        var rewrites: [HostnameRewrite] = []
        var candidates: [HostnameCandidate] = []

        for pair in environment {
            let before = pair.value
            // A value with a scheme is a URL and only gets tier A; anything else
            // only gets tier B. Keeping them exclusive means a value can never be
            // touched twice by two different rules.
            if before.contains("://") {
                let after = rewriteAuthorities(in: before, serviceNames: serviceNames, resolvedName: resolvedName)
                if after != before {
                    rewrites.append(
                        .init(service: service, key: pair.key, before: before, after: after, rule: .urlAuthority)
                    )
                }
                out.append(.init(key: pair.key, value: after))
                continue
            }

            let confidence = confidence(for: pair.key)
            let (after, matched) = rewritePieces(
                in: before,
                serviceNames: serviceNames,
                apply: confidence == .host,
                resolvedName: resolvedName
            )
            if after != before {
                rewrites.append(
                    .init(service: service, key: pair.key, before: before, after: after, rule: .hostPort)
                )
            } else if let matched, confidence == .ambiguous, matched != service {
                // Only genuinely ambiguous keys are surfaced. A deny-listed key
                // is one we are confident about, and a service naming itself is
                // never a hostname anybody needs. Reporting either would bury
                // the one case a user actually has to look at.
                candidates.append(
                    .init(service: service, key: pair.key, value: before, matchedService: matched)
                )
            }
            out.append(.init(key: pair.key, value: after))
        }

        return Result(environment: out, rewrites: rewrites, candidates: candidates)
    }

    // MARK: - Tier A

    private static let authority = try! NSRegularExpression(
        // The userinfo group is greedy and allows `@`, so an unencoded `@` in a
        // password still leaves the *host* as the final capture. `/` stays
        // excluded, so it can never run past the authority into a path.
        pattern: "(//)([^/\\s]*@)?([A-Za-z0-9_.\\-]+)"
    )

    /// Replaces only the host capture of each `//[user:pass@]host` it finds.
    ///
    /// A regex rather than `URLComponents`, which returns nil for
    /// `jdbc:postgresql://db:5432/app` and anything else whose scheme has an
    /// opaque part. Replacing a captured range also guarantees the credentials,
    /// port, path and query come through byte-identical.
    static func rewriteAuthorities(
        in value: String,
        serviceNames: Set<String>,
        resolvedName: (String) -> String
    ) -> String {
        let text = value as NSString
        let matches = authority.matches(in: value, range: NSRange(location: 0, length: text.length))
        var out = value
        // Back to front, so earlier ranges stay valid as later ones are replaced.
        for match in matches.reversed() {
            let hostRange = match.range(at: 3)
            guard hostRange.location != NSNotFound else { continue }
            let host = text.substring(with: hostRange)
            guard serviceNames.contains(host) else { continue }
            out = (out as NSString).replacingCharacters(in: hostRange, with: resolvedName(host))
        }
        return out
    }

    // MARK: - Tier B

    /// Splits on commas only, keeping the separators, and replaces a piece only
    /// when the whole trimmed piece is `service` or `service:port`.
    ///
    /// Commas and not whitespace: a comma-separated broker list is a real and
    /// common shape, while a space-separated one is not — and splitting on
    /// whitespace meant `APP_HOST="the db is over there"` had its middle word
    /// rewritten. A piece with internal whitespace simply never matches now.
    ///
    /// Returns the rewritten value and, when nothing was applied, the service a
    /// piece matched — which is what turns a skipped value into a reported
    /// candidate rather than silence.
    static func rewritePieces(
        in value: String,
        serviceNames: Set<String>,
        apply: Bool,
        resolvedName: (String) -> String
    ) -> (value: String, matched: String?) {
        var matched: String?
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)

        let rewritten = pieces.map { piece -> String in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let service = serviceOf(trimmed, serviceNames: serviceNames) else { return String(piece) }
            matched = matched ?? service
            guard apply else { return String(piece) }
            // Put the surrounding whitespace back exactly as it was written.
            let port = trimmed.dropFirst(service.count)
            return String(piece).replacingOccurrences(of: trimmed, with: resolvedName(service) + port)
        }

        return (rewritten.joined(separator: ","), matched)
    }

    /// The service a whole piece names, if it is exactly `service` or
    /// `service:port`.
    private static func serviceOf(_ piece: String, serviceNames: Set<String>) -> String? {
        if serviceNames.contains(piece) { return piece }
        guard let colon = piece.lastIndex(of: ":") else { return nil }
        let host = String(piece[piece.startIndex..<colon])
        let port = piece[piece.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber), serviceNames.contains(host) else { return nil }
        return host
    }
}
