import Foundation
import Testing

@testable import DockyardCore

@Suite struct ImageItemTests {

    @Test(arguments: [
        ("alpine:3.20", "alpine", "3.20"),
        ("docker.io/library/nginx:latest", "docker.io/library/nginx", "latest"),
        ("localhost:5000/app:dev", "localhost:5000/app", "dev"),
    ])
    func referenceSplitsIntoRepositoryAndTag(reference: String, repository: String, tag: String) {
        let item = ImageItem.stub(reference: reference, displayReference: reference)
        #expect(item.repository == repository)
        #expect(item.tag == tag)
    }

    /// A colon before the last `/` is a registry port, not a tag — splitting on
    /// it would turn `localhost:5000/app` into repository `localhost`.
    @Test func registryPortIsNotMistakenForATag() {
        let item = ImageItem.stub(reference: "localhost:5000/app", displayReference: "localhost:5000/app")
        #expect(item.repository == "localhost:5000/app")
        #expect(item.tag == nil)
    }

    @Test func untaggedReferenceHasNoTag() {
        let item = ImageItem.stub(reference: "alpine", displayReference: "alpine")
        #expect(item.repository == "alpine")
        #expect(item.tag == nil)
    }

    @Test func shortDigestDropsTheAlgorithmPrefix() {
        let item = ImageItem.stub()
        #expect(item.shortDigest == "0123456789ab")
    }
}

@Suite struct ContainerItemTests {

    @Test func primaryIPv4IsTheFirstAttachment() {
        let item = ContainerItem.stub(networks: [
            NetworkAttachment(network: "default", hostname: "web", ipv4Address: "192.168.64.3", gateway: "192.168.64.1"),
            NetworkAttachment(network: "other", hostname: "web", ipv4Address: "10.0.0.5", gateway: "10.0.0.1"),
        ])
        #expect(item.primaryIPv4 == "192.168.64.3")
    }

    @Test func containerWithoutNetworkHasNoIP() {
        #expect(ContainerItem.stub().primaryIPv4 == nil)
    }

    @Test func onlyStoppingCountsAsTransient() {
        #expect(ContainerStatus.stopping.isTransient)
        #expect(!ContainerStatus.running.isTransient)
        #expect(!ContainerStatus.stopped.isTransient)
        #expect(!ContainerStatus.unknown.isTransient)
    }
}

@Suite struct PortMappingTests {

    @Test func tcpPortsGetAClickableLocalURL() {
        let port = PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, networkProtocol: "tcp")
        #expect(port.localURL == URL(string: "http://localhost:8080"))
    }

    @Test func udpPortsHaveNoURL() {
        let port = PortMapping(hostAddress: "0.0.0.0", hostPort: 53, containerPort: 53, networkProtocol: "udp")
        #expect(port.localURL == nil)
    }
}

@Suite struct DaemonHealthTests {

    @Test func healthMatchingTheLinkedVersionIsAccepted() {
        #expect(DaemonHealth.stub().matchesLinkedVersion)
    }

    @Test func differentServerVersionIsFlagged() {
        #expect(!DaemonHealth.stub(version: "1.1.0").matchesLinkedVersion)
    }

    /// What the apiserver actually sends: the whole sentence, not a semver.
    @Test func versionIsExtractedFromTheServersFullSentence() {
        let health = DaemonHealth.stub(
            version: "container-apiserver version \(DockyardCore.linkedContainerVersion) "
                + "(build: release, commit: ee848e3)"
        )
        #expect(health.semanticVersion == DockyardCore.linkedContainerVersion)
        #expect(health.matchesLinkedVersion)
    }

    @Test func mismatchIsDetectedInsideTheFullSentence() {
        let health = DaemonHealth.stub(
            version: "container-apiserver version 2.3.4 (build: release, commit: abc1234)"
        )
        #expect(health.semanticVersion == "2.3.4")
        #expect(!health.matchesLinkedVersion)
    }

    @Test func bareSemverIsStillUnderstood() {
        #expect(DaemonHealth.stub(version: "1.0.0").semanticVersion == "1.0.0")
    }

    /// Never block the user over a version string we simply could not read.
    @Test func unparseableVersionIsTreatedAsAMatch() {
        let health = DaemonHealth.stub(version: "unspecified")
        #expect(health.semanticVersion == nil)
        #expect(health.matchesLinkedVersion)
    }

    @Test func commitIsShortenedForDisplay() {
        #expect(DaemonHealth.stub().shortCommit == "ee848e3")
    }
}
