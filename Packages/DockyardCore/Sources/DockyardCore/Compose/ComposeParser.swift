import Foundation
import Yams

/// Turns a compose document into a project spec plus diagnostics.
///
/// Pure: it takes text and an environment, never the filesystem, so every case
/// below is a one-line test. `ComposeLoader` is the part that reads files.
///
/// Walks a `Yams.Node` tree by hand rather than decoding into `Codable`
/// structs. Decoding discards `Node.Mark`, and a `DecodingError` for a
/// 200-line compose file names a coding path nobody can map back to a line.
public enum ComposeParser {

    /// Keys with no equivalent on this runtime. Each is reported by name, so a
    /// user can see what was skipped instead of wondering why it had no effect.
    private static let unsupportedServiceKeys: [String: String] = [
        "healthcheck": "This runtime has no health checks, so readiness cannot be observed.",
        "build": "Building from a compose file arrives in a later version; use a prebuilt image for now.",
        "networks": "Every container is attached to the default network, because that is the only one "
            + "where containers can resolve each other by name.",
        "container_name": "Dockyard names containers <project>-<service> so two projects can run at once.",
        "hostname": "The hostname is the container's name, which is what makes it resolvable.",
        "deploy": "Swarm-only.",
        "profiles": "Profiles arrive in a later version; every service is started.",
        "extends": "Extending another file is not supported yet.",
        "secrets": "Swarm secrets have no equivalent; use an environment variable or a mount.",
        "configs": "Swarm configs have no equivalent; use a mount.",
        "devices": "Device passthrough is not supported.",
        "privileged": "Privileged containers are not supported.",
        "network_mode": "Network mode cannot be changed.",
        "links": "Superseded by depends_on and name resolution.",
        "external_links": "Not supported.",
        "logging": "Log drivers are not configurable.",
    ]

    public static func parse(
        yaml: String,
        projectName: String,
        fileURL: URL,
        environment: [String: String]
    ) -> (spec: ComposeProjectSpec?, diagnostics: [ComposeDiagnostic]) {
        var diagnostics: [ComposeDiagnostic] = []

        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            let line = (error as? YamlError).flatMap(lineNumber(of:))
            diagnostics.append(
                .error("", "This file is not valid YAML. \(readable(error))", line: line)
            )
            return (nil, diagnostics)
        }

        guard let root, let top = root.mapping else {
            diagnostics.append(.error("", "A compose file has to be a mapping with a `services:` key."))
            return (nil, diagnostics)
        }

        // Interpolation happens on every scalar, before anything is interpreted.
        var failures: [ComposeInterpolation.Failure] = []
        func text(_ node: Node?) -> String? {
            guard let raw = node?.scalarString else { return nil }
            return ComposeInterpolation.expand(raw, values: environment, failures: &failures)
        }

        guard let servicesNode = top["services"], let services = servicesNode.mapping else {
            diagnostics.append(
                .error("services", "A compose file has to define at least one service.", line: line(top["services"]))
            )
            return (nil, diagnostics)
        }

        for key in top.keys where !["services", "volumes", "name", "version", "networks", "configs", "secrets"].contains(key.scalarString ?? "") {
            let name = key.scalarString ?? "?"
            guard !name.hasPrefix("x-") else { continue }
            diagnostics.append(.warning(name, "Dockyard does not understand this top-level key and skipped it.", line: line(key)))
        }
        if top["version"] != nil {
            diagnostics.append(.ignored("version", "The `version` key is obsolete and was ignored."))
        }
        if top["networks"] != nil {
            diagnostics.append(
                .ignored("networks", unsupportedServiceKeys["networks"] ?? "", line: line(top["networks"]))
            )
        }

        var parsed: [ComposeService] = []
        for (keyNode, serviceNode) in services {
            guard let name = keyNode.scalarString else { continue }
            let path = "services.\(name)"
            guard let body = serviceNode.mapping else {
                diagnostics.append(.error(path, "A service has to be a mapping.", line: line(serviceNode)))
                continue
            }
            guard let image = text(body["image"]), !image.isEmpty else {
                let hasBuild = body["build"] != nil
                diagnostics.append(
                    .error(
                        path,
                        hasBuild
                            ? "This service is built rather than pulled, which arrives in a later version."
                            : "This service has no `image:`.",
                        line: line(serviceNode)
                    )
                )
                continue
            }

            var service = ComposeService(name: name, image: image)
            service.command = text(body["command"]) ?? joined(body["command"], expand: text)
            service.entrypoint = text(body["entrypoint"]) ?? joined(body["entrypoint"], expand: text)
            service.workingDirectory = text(body["working_dir"]) ?? ""
            service.user = text(body["user"]) ?? ""
            service.platform = text(body["platform"]) ?? ""
            service.memory = text(body["mem_limit"]) ?? ""
            service.cpus = text(body["cpus"]) ?? ""
            service.shmSize = text(body["shm_size"]) ?? ""
            service.useInit = bool(body["init"])
            service.readOnlyRootFilesystem = bool(body["read_only"])
            service.allocateTerminal = bool(body["tty"])
            service.keepStdinOpen = bool(body["stdin_open"])
            service.tmpfs = strings(body["tmpfs"], expand: text)
            service.addedCapabilities = strings(body["cap_add"], expand: text)
            service.droppedCapabilities = strings(body["cap_drop"], expand: text)
            service.environment = keyValues(body["environment"], expand: text)
            service.envFiles = strings(body["env_file"], expand: text)
            service.labels = keyValues(body["labels"], expand: text)
            service.restart = restartPolicy(text(body["restart"]), path: path, into: &diagnostics, line: line(body["restart"]))
            service.dependsOn = dependencies(body["depends_on"], path: path, into: &diagnostics)
            service.ports = ports(body["ports"], path: path, expand: text, into: &diagnostics)
            service.volumes = mounts(body["volumes"], path: path, expand: text, into: &diagnostics)
            if let extensions = body["x-dockyard"]?.mapping, let rewrite = extensions["rewrite"] {
                service.rewriteHostnames = bool(rewrite)
            }

            for (key, reason) in unsupportedServiceKeys where body[key] != nil {
                diagnostics.append(.ignored("\(path).\(key)", reason, line: line(body[key])))
            }
            for key in body.keys {
                let name = key.scalarString ?? ""
                guard !name.isEmpty, !name.hasPrefix("x-"), !knownServiceKeys.contains(name),
                    unsupportedServiceKeys[name] == nil
                else { continue }
                // A warning, never an error: the compose spec grows, and
                // refusing a file over one unrecognised key would make the app
                // useless on files that otherwise run perfectly.
                diagnostics.append(
                    .warning("\(path).\(name)", "Dockyard does not understand this key and skipped it.", line: line(key))
                )
            }

            parsed.append(service)
        }

        for failure in failures {
            diagnostics.append(
                .error("", "`\(failure.variable)` \(failure.message)")
            )
        }

        guard !parsed.isEmpty else {
            if !diagnostics.blocks {
                diagnostics.append(.error("services", "None of the services in this file can be started."))
            }
            return (nil, diagnostics)
        }

        let volumes = declaredVolumes(top["volumes"])
        let spec = ComposeProjectSpec(
            name: text(top["name"]) ?? projectName,
            fileURL: fileURL,
            services: parsed,
            declaredVolumes: volumes
        )
        return (diagnostics.blocks ? nil : spec, diagnostics)
    }

    private static let knownServiceKeys: Set<String> = [
        "image", "command", "entrypoint", "environment", "env_file", "ports", "volumes",
        "depends_on", "working_dir", "user", "restart", "labels", "platform", "init",
        "read_only", "tty", "stdin_open", "tmpfs", "cap_add", "cap_drop", "shm_size",
        "mem_limit", "cpus",
    ]

    // MARK: - Pieces

    private static func restartPolicy(
        _ raw: String?,
        path: String,
        into diagnostics: inout [ComposeDiagnostic],
        line: Int?
    ) -> ComposeRestartPolicy {
        guard let raw, !raw.isEmpty else { return .no }
        guard let policy = ComposeRestartPolicy(labelValue: raw) else {
            diagnostics.append(.warning("\(path).restart", "“\(raw)” is not a restart policy; treated as `no`.", line: line))
            return .no
        }
        if policy.restartsAutomatically {
            diagnostics.append(
                .ignored(
                    "\(path).restart",
                    "Restarts are supervised by Dockyard and only happen while it is open.",
                    line: line
                )
            )
        }
        return policy
    }

    private static func dependencies(
        _ node: Node?,
        path: String,
        into diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        guard let node else { return [] }
        if let list = node.sequence {
            // Sorted like the mapping form below. Dependencies are a set, not a
            // sequence, so two files differing only in the order they list them
            // must produce the same spec — otherwise the config hash changes and
            // `up` recreates containers over a cosmetic edit.
            return list.compactMap(\.scalarString).sorted()
        }
        guard let map = node.mapping else { return [] }
        var names: [String] = []
        for (key, value) in map {
            guard let name = key.scalarString else { continue }
            names.append(name)
            let condition = value.mapping?["condition"]?.scalarString
            if let condition, condition != "service_started" {
                // We can observe a start; we cannot observe readiness. Saying so
                // is better than appearing to honour it.
                diagnostics.append(
                    .ignored(
                        "\(path).depends_on.\(name).condition",
                        "`\(condition)` needs health checks, which this runtime does not have — "
                            + "Dockyard waits for the container to start instead.",
                        line: line(value)
                    )
                )
            }
        }
        return names.sorted()
    }

    private static func ports(
        _ node: Node?,
        path: String,
        expand: (Node?) -> String?,
        into diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposePortMapping] {
        guard let list = node?.sequence else { return [] }
        var result: [ComposePortMapping] = []
        for entry in list {
            guard entry.mapping == nil else {
                diagnostics.append(
                    .ignored("\(path).ports", "Long-form port syntax is not supported yet; use \"8080:80\".", line: line(entry))
                )
                continue
            }
            guard let raw = expand(entry), !raw.isEmpty else { continue }
            guard let mapping = parsePort(raw) else {
                diagnostics.append(.warning("\(path).ports", "“\(raw)” is not a port mapping Dockyard understands.", line: line(entry)))
                continue
            }
            result.append(mapping)
        }
        return result
    }

    /// `[HOST:]CONTAINER[/PROTO]`, optionally with a bind address.
    static func parsePort(_ raw: String) -> ComposePortMapping? {
        var body = raw
        var networkProtocol = "tcp"
        if let slash = body.lastIndex(of: "/") {
            networkProtocol = String(body[body.index(after: slash)...]).lowercased()
            body = String(body[body.startIndex..<slash])
        }
        guard !body.contains("-") else { return nil }  // ranges are not supported

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let port = UInt16(parts[0]) else { return nil }
            return .init(hostAddress: nil, hostPort: port, containerPort: port, networkProtocol: networkProtocol)
        case 2:
            guard let host = UInt16(parts[0]), let container = UInt16(parts[1]) else { return nil }
            return .init(hostAddress: nil, hostPort: host, containerPort: container, networkProtocol: networkProtocol)
        case 3:
            guard let host = UInt16(parts[1]), let container = UInt16(parts[2]), !parts[0].isEmpty else { return nil }
            return .init(hostAddress: parts[0], hostPort: host, containerPort: container, networkProtocol: networkProtocol)
        default:
            return nil
        }
    }

    private static func mounts(
        _ node: Node?,
        path: String,
        expand: (Node?) -> String?,
        into diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeMount] {
        guard let list = node?.sequence else { return [] }
        var result: [ComposeMount] = []
        for entry in list {
            guard entry.mapping == nil else {
                diagnostics.append(
                    .ignored("\(path).volumes", "Long-form volume syntax is not supported yet; use \"./src:/app\".", line: line(entry))
                )
                continue
            }
            guard let raw = expand(entry), !raw.isEmpty else { continue }
            result.append(parseMount(raw))
        }
        return result
    }

    /// `[SOURCE:]TARGET[:MODE]`.
    static func parseMount(_ raw: String) -> ComposeMount {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return .init(kind: .anonymous, source: "", destination: parts[0], readOnly: false)
        default:
            let source = parts[0]
            let destination = parts[1]
            let readOnly = parts.count > 2 && parts[2].split(separator: ",").contains("ro")
            // A source that looks like a path is a bind; anything else names a
            // volume the runtime manages.
            let isPath = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
            return .init(kind: isPath ? .bind : .named, source: source, destination: destination, readOnly: readOnly)
        }
    }

    private static func declaredVolumes(_ node: Node?) -> [ComposeVolumeDeclaration] {
        guard let map = node?.mapping else { return [] }
        return map.compactMap { key, value in
            guard let name = key.scalarString else { return nil }
            let external = value.mapping?["external"].map { $0.bool ?? false } ?? false
            return ComposeVolumeDeclaration(name: name, isExternal: external)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Node helpers

    private static func keyValues(_ node: Node?, expand: (Node?) -> String?) -> [RunSpec.KeyValue] {
        guard let node else { return [] }
        // Both forms are equally common in the wild, and a parser that handles
        // only one rejects half of real files.
        if let map = node.mapping {
            return map.compactMap { key, value in
                guard let name = key.scalarString else { return nil }
                return RunSpec.KeyValue(key: name, value: expand(value) ?? "")
            }
            .sorted { $0.key < $1.key }
        }
        if let list = node.sequence {
            return list.compactMap { entry in
                guard let raw = expand(entry) else { return nil }
                let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = parts.first, !first.isEmpty else { return nil }
                return RunSpec.KeyValue(
                    key: String(first),
                    value: parts.count > 1 ? String(parts[1]) : ""
                )
            }
            .sorted { $0.key < $1.key }
        }
        return []
    }

    private static func strings(_ node: Node?, expand: (Node?) -> String?) -> [String] {
        guard let node else { return [] }
        if let single = expand(node), node.sequence == nil { return single.isEmpty ? [] : [single] }
        return node.sequence?.compactMap { expand($0) }.filter { !$0.isEmpty } ?? []
    }

    private static func joined(_ node: Node?, expand: (Node?) -> String?) -> String {
        guard let list = node?.sequence else { return "" }
        return list.compactMap { expand($0) }
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    private static func bool(_ node: Node?) -> Bool { node?.bool ?? false }

    private static func line(_ node: Node?) -> Int? {
        node?.mark.map { $0.line }
    }

    private static func lineNumber(of error: YamlError) -> Int? {
        if case .parser(let context, _, _, _) = error { return context?.mark.line }
        return nil
    }

    private static func readable(_ error: any Error) -> String {
        let text = "\(error)"
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

extension Node {
    /// The scalar's text, or nil for a mapping or a sequence.
    fileprivate var scalarString: String? {
        guard case .scalar(let scalar) = self else { return nil }
        return scalar.string
    }
}
