import ContainerAPIClient
import ContainerPersistence
import Foundation
import SystemPackage

/// Loads the runtime's own configuration (default registry, builder image, VM
/// init image, …), which several client APIs require as a parameter.
///
/// This mirrors `Application.loadContainerSystemConfig()` in
/// `ContainerCommands`. That module is deliberately not a dependency: it pulls
/// in ArgumentParser and terminal progress rendering that an app has no use for.
///
/// The result is cached because it costs a health-check round trip plus two file
/// reads, and it only changes when the daemon restarts.
actor SystemConfigLoader {
    private var cached: ContainerSystemConfig?

    func load() async throws -> ContainerSystemConfig {
        if let cached { return cached }
        let config = try await Self.fetch()
        cached = config
        return config
    }

    /// Drops the cache. Called when the daemon goes away, so a restarted server
    /// with different settings is not served stale configuration.
    func invalidate() {
        cached = nil
    }

    private static func fetch() async throws -> ContainerSystemConfig {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
            let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
            let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
            // Order matters: the loader takes the first match, and user settings
            // under appRoot must win over the defaults shipped in installRoot.
            return try await ConfigurationLoader.load(
                configurationFiles: [
                    ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                    ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
                ]
            )
        } catch {
            throw DockyardError(mapping: error)
        }
    }
}
