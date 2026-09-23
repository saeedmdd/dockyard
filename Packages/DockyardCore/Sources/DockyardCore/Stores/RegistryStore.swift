import Foundation
import Observation

/// Registry logins, pushes and archive import/export.
@MainActor
@Observable
public final class RegistryStore {
    public private(set) var logins: [RegistryLogin] = []
    public private(set) var actionError: DockyardError?
    public private(set) var isWorking = false
    /// A short note about something that succeeded, e.g. what was loaded.
    public private(set) var statusNote: String?

    /// Pushes in flight, shown the same way pulls are.
    public private(set) var pushes: [PullJob] = []

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public func refreshLogins() {
        do {
            logins = try backend.listRegistryLogins()
            actionError = nil
        } catch {
            // A keychain that cannot be read is worth saying out loud rather
            // than showing an empty list that looks like "no logins".
            actionError = DockyardError(mapping: error)
        }
    }

    @discardableResult
    public func logIn(_ credentials: RegistryCredentials, scheme: RegistryScheme = .auto) async -> Bool {
        actionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.logIn(credentials, scheme: scheme)
            refreshLogins()
            statusNote = "Signed in to \(credentials.trimmedHostname)"
            return true
        } catch {
            actionError = DockyardError(mapping: error)
            return false
        }
    }

    @discardableResult
    public func logOut(hostname: String) -> Bool {
        actionError = nil
        do {
            try backend.logOut(hostname: hostname)
            refreshLogins()
            return true
        } catch {
            actionError = DockyardError(mapping: error)
            return false
        }
    }

    // MARK: - Push

    @discardableResult
    public func push(reference: String, platform: String? = nil, scheme: RegistryScheme = .auto) -> PullJob {
        let job = PullJob(requestedReference: reference, platform: platform)
        pushes.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await progress in backend.pushImage(reference: reference, platform: platform, scheme: scheme) {
                    job.update(progress)
                }
                // A cancelled stream finishes rather than throwing, so success
                // is never inferred from the loop ending.
                try Task.checkCancellation()
                job.finish(.succeeded)
            } catch is CancellationError {
                job.finish(.cancelled)
            } catch {
                job.finish(.failed(DockyardError(mapping: error)))
            }
        }
        job.attach(task)
        return job
    }

    public func dismiss(_ job: PullJob) {
        pushes.removeAll { $0.id == job.id }
    }

    public func settlePushes() async {
        for job in pushes where !job.isFinished {
            await job.waitUntilFinished()
        }
    }

    // MARK: - Archives

    @discardableResult
    public func save(references: [String], to destination: URL) async -> Bool {
        actionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.saveImages(references: references, to: destination)
            statusNote = "Saved \(references.count) image\(references.count == 1 ? "" : "s") to \(destination.lastPathComponent)"
            return true
        } catch {
            actionError = DockyardError(mapping: error)
            return false
        }
    }

    @discardableResult
    public func load(from source: URL) async -> [String] {
        actionError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let loaded = try await backend.loadImages(from: source)
            statusNote = loaded.isEmpty
                ? "No images found in \(source.lastPathComponent)"
                : "Loaded \(loaded.joined(separator: ", "))"
            return loaded
        } catch {
            actionError = DockyardError(mapping: error)
            return []
        }
    }

    public func clearActionError() { actionError = nil }
    public func clearStatusNote() { statusNote = nil }
}
