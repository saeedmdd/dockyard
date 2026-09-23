import Foundation
import Testing

@testable import DockyardCore

@Suite struct NetworkSpecTests {

    @Test func nameIsRequired() {
        var spec = NetworkSpec()
        #expect(!spec.isValid)
        spec.name = "backend"
        #expect(spec.isValid)
    }

    @Test func modeDefaultsToNAT() {
        #expect(NetworkSpec().mode == .nat)
    }

    /// A blank subnet is fine — the runtime picks one.
    @Test func blankSubnetIsAllowed() {
        var spec = NetworkSpec()
        spec.name = "backend"
        spec.subnet = ""
        #expect(spec.isValid)
    }

    @Test(arguments: ["192.168.70.0/24", "10.0.0.0/8", "172.16.5.0/16"])
    func validSubnetsAreAccepted(subnet: String) {
        #expect(NetworkSpec.isValidSubnet(subnet), "\(subnet) should be valid")
    }

    @Test(arguments: ["192.168.70.0", "192.168.70.0/33", "999.1.1.1/24", "not-a-subnet", "192.168/24"])
    func malformedSubnetsAreRejected(subnet: String) {
        #expect(!NetworkSpec.isValidSubnet(subnet), "\(subnet) should be rejected")
    }

    @Test func malformedSubnetIsReportedOnTheSpec() {
        var spec = NetworkSpec()
        spec.name = "backend"
        spec.subnet = "192.168.70.0"
        #expect(!spec.isValid)
        #expect(spec.validationProblems.contains { $0.contains("CIDR") })
    }

    @Test func modesDescribeThemselves() {
        for mode in NetworkItem.Mode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.detail.isEmpty)
        }
    }
}

@MainActor
@Suite struct NetworkStoreTests {

    private func store(_ networks: [NetworkItem] = []) -> (NetworkStore, MockBackend) {
        let backend = MockBackend()
        backend.setNetworks(networks)
        return (NetworkStore(backend: backend), backend)
    }

    @Test func refreshLoadsNetworksSorted() async {
        let (store, _) = store([.stub(name: "zebra"), .stub(name: "alpha")])

        await store.refresh()

        #expect(store.items.map(\.name) == ["alpha", "zebra"])
    }

    @Test func createAddsANetwork() async {
        let (store, _) = store()
        var spec = NetworkSpec()
        spec.name = "backend"

        let created = await store.create(spec)

        #expect(created?.name == "backend")
        #expect(store.items.map(\.name) == ["backend"])
    }

    @Test func duplicateNameIsReported() async {
        let (store, _) = store([.stub(name: "backend")])
        await store.refresh()
        var spec = NetworkSpec()
        spec.name = "backend"

        #expect(await store.create(spec) == nil)
        #expect(store.actionError != nil)
    }

    @Test func deleteRemovesANetwork() async {
        let (store, _) = store([.stub(name: "backend")])
        await store.refresh()

        #expect(await store.delete("backend"))
        #expect(store.items.isEmpty)
    }

    /// The runtime needs its built-in network; deleting it would break every
    /// container on the machine.
    @Test func theBuiltinNetworkCannotBeDeleted() async {
        let (store, _) = store([.stub(name: "default", isBuiltin: true)])
        await store.refresh()

        let ok = await store.delete("default")

        #expect(!ok)
        #expect(store.actionError != nil)
        #expect(store.items.count == 1, "it must still be there")
    }

    @Test func containersOnANetworkAreFound() async {
        let (store, _) = store([.stub(name: "backend")])
        await store.refresh()
        let network = store.items[0]
        let containers = [
            ContainerItem.stub(
                id: "web",
                networks: [
                    NetworkAttachment(network: "backend", hostname: "web", ipv4Address: "10.0.0.2", gateway: "10.0.0.1")
                ]
            ),
            ContainerItem.stub(
                id: "other",
                networks: [
                    NetworkAttachment(network: "default", hostname: "other", ipv4Address: "192.168.64.3", gateway: "192.168.64.1")
                ]
            ),
        ]

        #expect(store.containersOn(network, in: containers).map(\.id) == ["web"])
    }

    @Test func daemonDownClearsWithoutReportingAnError() async {
        let (store, backend) = store([.stub(name: "backend")])
        await store.refresh()
        backend.setFailure(.daemonUnreachable("down"))

        await store.refresh()

        #expect(store.items.isEmpty)
        #expect(store.lastError == nil)
    }
}
