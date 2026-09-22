import Foundation
import Testing

@testable import DockyardCore

@MainActor
@Suite struct ContainerDetailStoreTests {

    private func store(_ containers: [ContainerItem] = [.stub(id: "web")]) -> (ContainerDetailStore, MockBackend) {
        let backend = MockBackend(containers: containers)
        return (ContainerDetailStore(backend: backend), backend)
    }

    @Test func selectingLoadsTheDetail() async {
        let (store, backend) = store()

        await store.select("web")

        #expect(store.detail?.id == "web")
        #expect(backend.calls.detail == 1)
        #expect(!store.isLoading)
    }

    @Test func selectingTheSameContainerTwiceDoesNotReload() async {
        let (store, backend) = store()

        await store.select("web")
        await store.select("web")

        #expect(backend.calls.detail == 1, "re-selecting the same row should not refetch")
    }

    /// Switching rows must not leave the previous container's data on screen.
    @Test func switchingContainersClearsStaleData() async {
        let (store, _) = store([.stub(id: "web"), .stub(id: "db")])
        await store.select("web")
        await store.loadInspectJSON()
        #expect(store.inspectJSON?.contains("web") == true)

        await store.select("db")

        #expect(store.detail?.id == "db")
        #expect(store.inspectJSON == nil, "inspect JSON must not carry over to another container")
    }

    @Test func deselectingEmptiesThePane() async {
        let (store, _) = store()
        await store.select("web")

        await store.select(nil)

        #expect(store.detail == nil)
        #expect(store.containerID == nil)
    }

    /// The inspect tab costs an extra round trip, so it is only paid for when
    /// that tab is actually opened.
    @Test func inspectJSONIsFetchedOnlyOnDemandAndOnce() async {
        let (store, backend) = store()
        await store.select("web")
        #expect(backend.calls.inspect == 0, "selecting a row must not fetch inspect JSON")

        await store.loadInspectJSON()
        await store.loadInspectJSON()

        #expect(backend.calls.inspect == 1)
        #expect(store.inspectJSON?.contains("\"id\"") == true)
    }

    /// A container deleted elsewhere while selected: empty the pane, do not crash.
    @Test func containerDisappearingEmptiesThePane() async {
        let (store, backend) = store()
        await store.select("web")
        #expect(store.detail != nil)

        backend.setContainers([])
        await store.refresh()

        #expect(store.detail == nil)
        #expect(store.lastError != nil)
    }

    @Test func refreshWithNothingSelectedDoesNothing() async {
        let (store, backend) = store()

        await store.refresh()

        #expect(backend.calls.detail == 0)
    }

    /// A stopped daemon is the window's problem, not the pane's.
    @Test func daemonDownEmptiesWithoutReportingAnError() async {
        let (store, backend) = store()
        await store.select("web")
        backend.setFailure(.daemonUnreachable("down"))

        await store.refresh()

        #expect(store.detail == nil)
        #expect(store.lastError == nil)
    }
}

@Suite struct ContainerDetailModelTests {

    @Test func commandLineJoinsExecutableAndArguments() {
        let detail = ContainerDetail.stub()
        #expect(detail.commandLine == "/docker-entrypoint.sh nginx -g daemon off;")
    }

    /// The root filesystem is an implementation detail, not a mount the user
    /// chose, so it is kept out of the Mounts list.
    @Test func rootFilesystemIsHiddenFromMounts() {
        let detail = ContainerDetail.stub()

        #expect(detail.mounts.count == 3)
        #expect(detail.userVisibleMounts.count == 2)
        #expect(!detail.userVisibleMounts.contains { $0.destination == "/" })
    }

    /// These are the ones that break a start when the folder goes away, which
    /// is what the start pre-flight in T05 checks.
    @Test func hostFolderMountsAreIdentified() {
        let detail = ContainerDetail.stub()

        let hostFolders = detail.hostFolderMounts.map(\.destination)
        #expect(hostFolders.contains("/usr/share/nginx/html"))
        #expect(!hostFolders.contains("/var/cache"), "a volume is not a host folder")
    }

    @Test func mountKindsHaveTitlesAndSymbols() {
        for kind in [MountInfo.Kind.block, .volume, .virtiofs, .tmpfs] {
            #expect(!kind.title.isEmpty)
            #expect(!kind.symbol.isEmpty)
        }
    }
}

@Suite struct EnvironmentParsingTests {

    /// Environment entries are `KEY=value` strings and values routinely contain
    /// `=` themselves — a naive split would truncate them.
    @Test func valuesContainingEqualsSignsSurviveIntact() {
        let entries = [
            "PATH=/usr/bin:/bin",
            "QUERY=a=1&b=2",
            "EMPTY=",
            "NOEQUALS",
        ]

        let parsed = Dictionary(
            entries.compactMap { entry -> (String, String)? in
                guard let separator = entry.firstIndex(of: "=") else { return (entry, "") }
                return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
            },
            uniquingKeysWith: { _, last in last }
        )

        #expect(parsed["PATH"] == "/usr/bin:/bin")
        #expect(parsed["QUERY"] == "a=1&b=2")
        #expect(parsed["EMPTY"] == "")
        #expect(parsed["NOEQUALS"] == "")
    }
}
