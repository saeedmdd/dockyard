import Foundation

/// Everything Dockyard can ask of the container runtime.
///
/// One protocol, two implementations: `LiveBackend` talks XPC to
/// `container-apiserver`, and tests use an in-memory double. Stores depend only
/// on this, so no view or store ever imports an upstream module.
///
/// Implementations throw `DockyardError`; callers can rely on that and on
/// `DockyardError.isDaemonDown` to decide between a per-row error and the
/// daemon-down screen.
///
/// Later tasks extend this: lifecycle actions (T05), logs (T07), stats (T08),
/// pull/build (T09/T13), volumes and networks (T15/T16).
public protocol ContainerBackend: Sendable {
    /// Pings `container-apiserver`. Throws `.daemonUnreachable` when it is not
    /// running, which is how the app detects the daemon-down state.
    func health() async throws -> DaemonHealth

    /// All containers, running or not, excluding the runtime's own machine VMs.
    func listContainers() async throws -> [ContainerItem]

    /// Boots a stopped container and starts its init process, detached.
    /// A container that is already running is left alone.
    func startContainer(id: String) async throws

    /// Asks a container to stop, giving its process time to exit before the
    /// runtime forces the issue.
    func stopContainer(id: String) async throws

    /// Sends a signal, typically to end a container that will not stop.
    func killContainer(id: String, signal: ProcessSignal) async throws

    /// Removes a container. Running containers require `force`.
    func deleteContainer(id: String, force: Bool) async throws

    /// All images, including infrastructure ones flagged via
    /// `ImageItem.isInfrastructure` so the UI can filter them.
    func listImages() async throws -> [ImageItem]

    /// Total size of an image in bytes. Separate from `listImages()` because it
    /// costs an index fetch plus a manifest fetch per image.
    func imageSize(reference: String) async throws -> Int64
}
