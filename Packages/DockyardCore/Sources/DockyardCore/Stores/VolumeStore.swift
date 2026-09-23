import Foundation
import Observation

/// The volumes list.
@MainActor
@Observable
public final class VolumeStore {
    public private(set) var items: [VolumeItem] = []
    public private(set) var isLoadingInitially = true
    public private(set) var lastError: DockyardError?
    /// A failure from create or delete, kept apart from `lastError` because
    /// every action refreshes the list and a successful refresh would clear it.
    public private(set) var actionError: DockyardError?

    /// Bytes used per volume, filled in lazily.
    ///
    /// Each figure is a separate call, so they are fetched only for volumes on
    /// screen rather than on every poll of the whole list.
    public private(set) var diskUsage: [String: UInt64] = [:]

    private let backend: any ContainerBackend

    public init(backend: any ContainerBackend) {
        self.backend = backend
    }

    public func refresh() async {
        do {
            items = try await backend.listVolumes()
            lastError = nil
            // A volume that has gone does not keep a stale size.
            let names = Set(items.map(\.name))
            diskUsage = diskUsage.filter { names.contains($0.key) }
        } catch let error as DockyardError where error.isDaemonDown {
            items = []
            lastError = nil
        } catch {
            lastError = DockyardError(mapping: error)
        }
        isLoadingInitially = false
    }

    /// Containers with this volume mounted.
    ///
    /// Deleting a volume a container depends on leaves that container unable to
    /// start, so the UI asks first.
    public func containersUsing(_ volume: VolumeItem, in containers: [ContainerDetail]) -> [ContainerDetail] {
        containers.filter { detail in
            detail.mounts.contains { $0.volumeName == volume.name }
        }
    }

    public func loadDiskUsage(for name: String) async {
        guard diskUsage[name] == nil else { return }
        if let bytes = try? await backend.volumeDiskUsage(name: name) {
            diskUsage[name] = bytes
        }
    }

    @discardableResult
    public func create(_ spec: VolumeSpec) async -> VolumeItem? {
        actionError = nil
        do {
            let volume = try await backend.createVolume(spec)
            await refresh()
            return volume
        } catch {
            actionError = DockyardError(mapping: error)
            return nil
        }
    }

    @discardableResult
    public func delete(_ name: String) async -> Bool {
        actionError = nil
        do {
            try await backend.deleteVolume(name: name)
            await refresh()
            return true
        } catch {
            actionError = DockyardError(mapping: error)
            return false
        }
    }

    public func clearActionError() {
        actionError = nil
    }
}
