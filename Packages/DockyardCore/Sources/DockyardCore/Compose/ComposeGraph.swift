import Foundation

/// What order services start in, from their `depends_on` edges.
public enum ComposeGraph {

    public enum Problem: Error, Sendable, Equatable {
        /// The members of one cycle, in the order they depend on each other and
        /// closing back on the first: `web → api → db → web`.
        case cycle([String])
        case unknownDependency(service: String, missing: String)

        public var message: String {
            switch self {
            case .cycle(let members):
                let loop = (members + [members.first ?? ""]).joined(separator: " → ")
                return "Services depend on each other in a loop: \(loop)."
            case .unknownDependency(let service, let missing):
                return "“\(service)” depends on “\(missing)”, which this file does not define."
            }
        }
    }

    /// Start order: every service after the ones it depends on.
    ///
    /// Ties are broken by name rather than by whatever order the dictionary
    /// happened to iterate in, so two runs of the same file — on two machines,
    /// or before and after an edit elsewhere — produce the same order. A
    /// non-deterministic start order turns an intermittent race into an
    /// unreproducible one.
    public static func startOrder(_ services: [ComposeService]) -> Result<[String], Problem> {
        let names = Set(services.map(\.name))
        for service in services.sorted(by: { $0.name < $1.name }) {
            for dependency in service.dependsOn.sorted() where !names.contains(dependency) {
                return .failure(.unknownDependency(service: service.name, missing: dependency))
            }
        }

        var remaining: [String: Set<String>] = [:]
        for service in services {
            remaining[service.name] = Set(service.dependsOn)
        }

        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.value.isEmpty }.keys.sorted()
            guard let next = ready.first else {
                // Kahn stalls on a cycle but cannot say which services form it,
                // and "there is a cycle somewhere" is not a fixable message.
                return .failure(.cycle(findCycle(in: remaining)))
            }
            ordered.append(next)
            remaining.removeValue(forKey: next)
            for key in remaining.keys {
                remaining[key]?.remove(next)
            }
        }
        return .success(ordered)
    }

    /// Reverse of the start order: a service stops before what it depends on.
    public static func stopOrder(_ services: [ComposeService]) -> Result<[String], Problem> {
        startOrder(services).map { $0.reversed() }
    }

    /// Walks the services Kahn could not place and recovers one real cycle, so
    /// the message can name its members instead of gesturing at the file.
    private static func findCycle(in remaining: [String: Set<String>]) -> [String] {
        var visiting: [String] = []
        var onPath: Set<String> = []
        var done: Set<String> = []
        var found: [String] = []

        func walk(_ node: String) -> Bool {
            if onPath.contains(node) {
                // Trim the prefix that merely led us here; what is left is the loop.
                if let start = visiting.firstIndex(of: node) {
                    found = Array(visiting[start...])
                }
                return true
            }
            if done.contains(node) { return false }
            onPath.insert(node)
            visiting.append(node)
            for next in (remaining[node] ?? []).sorted() where remaining[next] != nil {
                if walk(next) { return true }
            }
            visiting.removeLast()
            onPath.remove(node)
            done.insert(node)
            return false
        }

        for node in remaining.keys.sorted() where walk(node) {
            return found
        }
        return remaining.keys.sorted()
    }
}
