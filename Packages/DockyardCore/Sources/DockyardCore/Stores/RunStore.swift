import Foundation
import Observation

/// Drives creating a container from the Run sheet.
///
/// Creating can take a while — the image may need fetching and unpacking — so
/// this reports progress the same way a pull does and stays observable while
/// the sheet is open.
@MainActor
@Observable
public final class RunStore {
    public enum State: Sendable, Equatable {
        case idle
        case working(PullProgress)
        case created(id: String)
        case failed(DockyardError)
        case cancelled
    }

    public private(set) var state: State = .idle

    private let backend: any ContainerBackend
    private var task: Task<String?, Never>?

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    public var progress: PullProgress? {
        if case .working(let progress) = state { return progress }
        return nil
    }

    /// Creates the container, optionally starting it, and reports the id.
    ///
    /// Returns the new id on success so the caller can select it in the list.
    @discardableResult
    public func create(spec: RunSpec, then start: Bool) async -> String? {
        guard !isWorking else { return nil }
        state = .working(PullProgress())

        let task = Task { () -> String? in
            var createdID: String?
            do {
                for try await update in backend.createContainer(spec: spec) {
                    switch update {
                    case .working(let progress):
                        state = .working(progress)
                    case .created(let id):
                        createdID = id
                    }
                }
                // As in T09: cancelling a stream consumer makes it finish
                // rather than throw, so success is never assumed from the loop
                // ending.
                try Task.checkCancellation()
                guard let createdID else {
                    state = .failed(.other("The container was not created."))
                    return nil
                }
                if start {
                    try await backend.startContainer(id: createdID)
                }
                state = .created(id: createdID)
                return createdID
            } catch is CancellationError {
                state = .cancelled
                return nil
            } catch {
                state = .failed(DockyardError(mapping: error))
                return nil
            }
        }
        self.task = task
        let id = await task.value
        self.task = nil
        return id
    }

    public func cancel() {
        task?.cancel()
    }

    public func reset() {
        task?.cancel()
        task = nil
        state = .idle
    }
}
