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

    /// Everything about one container, for the detail pane.
    func containerDetail(id: String) async throws -> ContainerDetail

    /// The container's full configuration and runtime state as pretty JSON,
    /// matching `container inspect`.
    func containerInspectJSON(id: String) async throws -> String

    /// A reading of a running container's resource counters.
    func containerStats(id: String) async throws -> RawContainerStats

    /// Starts a process inside a running container and returns a handle to it.
    func exec(_ request: ExecRequest) async throws -> any ExecSessionHandle

    /// Runs a command inside a running container and collects its output.
    /// Used for one-shot commands rather than an interactive session.
    func execCapturing(containerID: String, command: [String]) async throws -> (output: String, exitCode: Int32)

    /// Named volumes the runtime manages.
    func listVolumes() async throws -> [VolumeItem]

    /// Creates a volume and returns it as the runtime recorded it.
    @discardableResult
    func createVolume(_ spec: VolumeSpec) async throws -> VolumeItem

    func deleteVolume(name: String) async throws

    /// Bytes a volume is actually using, which is a separate query from listing.
    func volumeDiskUsage(name: String) async throws -> UInt64

    /// Open file handles for a container's logs.
    ///
    /// These are ordinary files the runtime appends to, so following one means
    /// watching a file rather than reading a stream.
    func logHandles(id: String) async throws -> ContainerLogHandles

    /// Creates a container from a `RunSpec`, fetching and unpacking the image
    /// if it is not already present. Progress covers that fetch, so the sheet
    /// can show the same detail a pull does. The stream's final value carries
    /// the new container's id.
    func createContainer(spec: RunSpec) -> AsyncThrowingStream<CreateProgress, any Error>

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

    /// Pulls an image, reporting progress as it goes, and unpacks it so it is
    /// ready to run. The stream finishes when the image is usable.
    func pullImage(reference: String, platform: String?) -> AsyncThrowingStream<PullProgress, any Error>

    /// Everything about one image, including its per-platform variants.
    func imageDetail(reference: String) async throws -> ImageDetail

    /// The image's resolved configuration as pretty JSON, matching
    /// `container image inspect`.
    func imageInspectJSON(reference: String) async throws -> String

    /// Deletes an image and collects blobs nothing references any more.
    @discardableResult
    func deleteImage(reference: String) async throws -> ImageDeletionResult

    /// Points a second reference at the same image.
    func tagImage(reference: String, newReference: String) async throws

    /// Total size of an image in bytes. Separate from `listImages()` because it
    /// costs an index fetch plus a manifest fetch per image.
    func imageSize(reference: String) async throws -> Int64
}
