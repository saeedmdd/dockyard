import Foundation
import Observation

/// The images list.
@MainActor
@Observable
public final class ImageStore {
    public private(set) var items: [ImageItem] = []
    public private(set) var isLoadingInitially = true
    public private(set) var lastError: DockyardError?

    /// Whether the runtime's own builder and VM init images are listed.
    /// Hidden by default, matching `container image list`. T10 adds the toggle.
    public var showsInfrastructure = false

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    /// What the list should display, honouring `showsInfrastructure`.
    public var visibleItems: [ImageItem] {
        showsInfrastructure ? items : items.filter { !$0.isInfrastructure }
    }

    public var infrastructureCount: Int {
        items.count { $0.isInfrastructure }
    }

    /// Pulls in flight, plus the last few that finished so a failure does not
    /// vanish before it can be read.
    public private(set) var pulls: [PullJob] = []

    public var activePulls: [PullJob] {
        pulls.filter { !$0.isFinished }
    }

    /// Starts a pull. The job appears immediately so the user sees the click
    /// register, even before the registry has answered.
    @discardableResult
    public func pull(reference: String, platform: String? = nil) -> PullJob {
        let job = PullJob(requestedReference: reference, platform: platform)
        pulls.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await progress in backend.pullImage(reference: reference, platform: platform) {
                    job.update(progress)
                }
                // Cancelling the consuming task makes an AsyncThrowingStream
                // *finish* rather than throw, so the loop above exits normally
                // and a cancelled pull would otherwise report "Pulled and
                // unpacked" for an image that was never fetched.
                try Task.checkCancellation()
                job.finish(.succeeded)
                await self.refresh()
            } catch is CancellationError {
                job.finish(.cancelled)
                // A cancelled pull may still have left blobs behind, so the
                // list is refreshed either way.
                await self.refresh()
            } catch {
                job.finish(.failed(DockyardError(mapping: error)))
            }
        }
        job.attach(task)
        return job
    }

    /// Waits for every in-flight pull to finish. Used by tests, and by any
    /// caller that needs the list to be settled.
    public func settlePulls() async {
        for job in pulls where !job.isFinished {
            await job.waitUntilFinished()
        }
    }

    /// Removes a finished job from the list.
    public func dismiss(_ job: PullJob) {
        pulls.removeAll { $0.id == job.id }
    }

    public func dismissFinishedPulls() {
        pulls.removeAll(where: \.isFinished)
    }

    public func refresh() async {
        do {
            items = try await backend.listImages()
            lastError = nil
        } catch let error as DockyardError where error.isDaemonDown {
            items = []
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoadingInitially = false
    }
}
