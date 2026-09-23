import Foundation

/// Reads a compose file and everything it refers to.
///
/// The only compose type that touches the filesystem — the parser is pure, so
/// this is the one place a path can be resolved wrongly.
public struct ComposeLoader: Sendable {
    private let processEnvironment: [String: String]

    /// `FileManager` is not `Sendable`, and the operations used here are the
    /// thread-safe ones, so `.default` is used directly rather than stored.
    /// Tests work against real temporary files, which is the more faithful
    /// arrangement anyway — path resolution is the thing most likely to be
    /// wrong, and a stubbed filesystem would not catch it.
    private var fileManager: FileManager { .default }

    public init(processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.processEnvironment = processEnvironment
    }

    /// The names compose looks for, in the order it prefers them.
    public static let conventionalNames = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    ]

    /// The compose file in a directory, if there is one.
    public func discover(in directory: URL) -> URL? {
        Self.conventionalNames
            .map { directory.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    public func load(
        fileURL: URL,
        projectName: String? = nil
    ) -> (spec: ComposeProjectSpec?, diagnostics: [ComposeDiagnostic]) {
        var diagnostics: [ComposeDiagnostic] = []

        let yaml: String
        do {
            yaml = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return (nil, [.error("", "Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")])
        }

        let directory = fileURL.deletingLastPathComponent()
        let dotEnv = readEnvFile(directory.appendingPathComponent(".env"))
        let values = ComposeInterpolation.values(
            processEnvironment: processEnvironment,
            dotEnv: dotEnv
        )

        let fallbackName = projectName ?? Self.projectName(for: directory)
        var (spec, parsed) = ComposeParser.parse(
            yaml: yaml,
            projectName: fallbackName,
            fileURL: fileURL,
            environment: values
        )
        diagnostics.append(contentsOf: parsed)
        guard var spec else { return (nil, diagnostics) }

        // env_file is read here rather than handed to the runtime: upstream's
        // --env-file resolves relative paths against *Dockyard's* working
        // directory, not the compose file's, so `env_file: .env.local` would
        // silently miss. Reading it also brings those values inside hostname
        // rewriting, which they would otherwise escape.
        spec.services = spec.services.map { service in
            var service = service
            guard !service.envFiles.isEmpty else { return service }
            var merged: [String: String] = [:]
            for relative in service.envFiles {
                let url = Self.resolve(relative, against: directory)
                guard fileManager.fileExists(atPath: url.path) else {
                    diagnostics.append(
                        .error(
                            "services.\(service.name).env_file",
                            "“\(relative)” does not exist next to the compose file."
                        )
                    )
                    continue
                }
                merged.merge(readEnvFile(url)) { _, later in later }
            }
            // A value written in `environment:` beats one from a file.
            for pair in service.environment {
                merged[pair.key] = pair.value
            }
            service.environment = merged.keys.sorted().map { .init(key: $0, value: merged[$0] ?? "") }
            return service
        }

        if diagnostics.blocks { return (nil, diagnostics) }
        return (spec, diagnostics)
    }

    /// A default project name from the folder, sanitised into something the
    /// runtime will accept as part of a container name.
    public static func projectName(for directory: URL) -> String {
        sanitise(directory.lastPathComponent)
    }

    /// Lowercased, non-alphanumerics folded to `-`, runs collapsed, trimmed.
    /// The result still has to pass `EntityName`, which T24 checks.
    public static func sanitise(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    static func resolve(_ path: String, against directory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    /// `KEY=value` lines, `#` comments, optional `export `, optional quotes.
    func readEnvFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return Self.parseEnv(text)
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
                (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
