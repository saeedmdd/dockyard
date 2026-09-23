import Foundation
import Testing

@testable import DockyardCore

@Suite struct VolumeSpecTests {

    @Test func nameIsRequired() {
        var spec = VolumeSpec()
        #expect(!spec.isValid)
        #expect(spec.validationProblems.contains { $0.contains("name") })

        spec.name = "data"
        #expect(spec.isValid)
    }

    @Test func whitespaceIsTrimmed() {
        var spec = VolumeSpec()
        spec.name = "  data  "
        #expect(spec.trimmedName == "data")
        #expect(spec.isValid)
    }

    /// Mirrors the runtime's entity-name rule, which needs two characters and
    /// an alphanumeric first one.
    @Test(arguments: ["data", "my-data", "my.data_2", "a1"])
    func validNamesAreAccepted(name: String) {
        var spec = VolumeSpec()
        spec.name = name
        #expect(spec.isValid, "\(name) should be valid")
    }

    @Test(arguments: ["has space", "-leading", "_leading", "a"])
    func questionableNamesAreCaught(name: String) {
        var spec = VolumeSpec()
        spec.name = name
        #expect(!spec.isValid, "\(name) should be rejected")
    }

    @Test func driverDefaultsToLocal() {
        #expect(VolumeSpec().driver == "local")
    }
}

@MainActor
@Suite struct VolumeStoreTests {

    private func store(_ volumes: [VolumeItem] = []) -> (VolumeStore, MockBackend) {
        let backend = MockBackend()
        backend.setVolumes(volumes)
        return (VolumeStore(backend: backend), backend)
    }

    @Test func refreshLoadsVolumesSorted() async {
        let (store, _) = store([.stub(name: "zebra"), .stub(name: "alpha")])

        await store.refresh()

        #expect(store.items.map(\.name) == ["alpha", "zebra"])
        #expect(!store.isLoadingInitially)
    }

    @Test func createAddsAVolume() async {
        let (store, _) = store()
        var spec = VolumeSpec()
        spec.name = "data"

        let created = await store.create(spec)

        #expect(created?.name == "data")
        #expect(store.items.map(\.name) == ["data"])
        #expect(store.actionError == nil)
    }

    @Test func creatingADuplicateReportsTheError() async {
        let (store, _) = store([.stub(name: "data")])
        await store.refresh()
        var spec = VolumeSpec()
        spec.name = "data"

        let created = await store.create(spec)

        #expect(created == nil)
        #expect(store.actionError != nil)
        #expect(store.items.count == 1)
    }

    @Test func deleteRemovesAVolume() async {
        let (store, _) = store([.stub(name: "data")])
        await store.refresh()

        let ok = await store.delete("data")

        #expect(ok)
        #expect(store.items.isEmpty)
    }

    /// A failed delete must survive the refresh that follows it.
    @Test func deleteFailureIsKept() async {
        let (store, backend) = store([.stub(name: "data")])
        await store.refresh()
        backend.setFailure(.upstream(code: "internalError", message: "volume in use"))

        let ok = await store.delete("data")

        #expect(!ok)
        #expect(store.actionError == .upstream(code: "internalError", message: "volume in use"))
    }

    /// Deleting a volume a container mounts leaves that container unable to
    /// start, so the UI needs to know before asking.
    @Test func containersMountingAVolumeAreFound() async {
        let (store, _) = store([.stub(name: "data")])
        await store.refresh()
        let volume = store.items[0]

        let details = [
            ContainerDetail.stub(id: "web").withMounts([
                MountInfo(kind: .volume, source: "data", destination: "/data", isReadOnly: false, volumeName: "data")
            ]),
            ContainerDetail.stub(id: "other").withMounts([
                MountInfo(kind: .volume, source: "cache", destination: "/cache", isReadOnly: false, volumeName: "cache")
            ]),
        ]

        let users = store.containersUsing(volume, in: details)

        #expect(users.map(\.id) == ["web"])
    }

    /// Sizes are a separate call each, so they are fetched on demand and only
    /// once per volume.
    @Test func diskUsageIsFetchedLazilyAndCached() async {
        let (store, backend) = store([.stub(name: "data")])
        backend.setVolumeUsage(["data": 4_096_000])
        await store.refresh()
        #expect(backend.calls.volumeUsage == 0, "listing must not price every volume")

        await store.loadDiskUsage(for: "data")
        await store.loadDiskUsage(for: "data")

        #expect(backend.calls.volumeUsage == 1)
        #expect(store.diskUsage["data"] == 4_096_000)
    }

    /// A deleted volume must not keep a size behind in the cache.
    @Test func sizesAreDroppedForVolumesThatDisappear() async {
        let (store, backend) = store([.stub(name: "data")])
        backend.setVolumeUsage(["data": 1024])
        await store.refresh()
        await store.loadDiskUsage(for: "data")
        #expect(store.diskUsage["data"] == 1024)

        backend.setVolumes([])
        await store.refresh()

        #expect(store.diskUsage["data"] == nil)
    }

    @Test func daemonDownClearsWithoutReportingAnError() async {
        let (store, backend) = store([.stub(name: "data")])
        await store.refresh()
        backend.setFailure(.daemonUnreachable("down"))

        await store.refresh()

        #expect(store.items.isEmpty)
        #expect(store.lastError == nil)
    }
}

extension ContainerDetail {
    /// A copy with different mounts, for testing the in-use check.
    func withMounts(_ mounts: [MountInfo]) -> ContainerDetail {
        ContainerDetail(
            id: id, image: image, status: status, startedAt: startedAt, createdAt: createdAt,
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, user: user, hasTerminal: hasTerminal,
            cpus: cpus, memoryInBytes: memoryInBytes, os: os, architecture: architecture,
            runtimeHandler: runtimeHandler, isVirtualizationEnabled: isVirtualizationEnabled,
            isRosettaEnabled: isRosettaEnabled, isReadOnlyRootFilesystem: isReadOnlyRootFilesystem,
            ports: ports, networks: networks, mounts: mounts,
            dnsNameservers: dnsNameservers, dnsDomain: dnsDomain,
            dnsSearchDomains: dnsSearchDomains, labels: labels
        )
    }
}
