import Foundation
import Testing

@testable import DockyardCore

/// The one matching rule every list's search field uses.
@Suite struct SearchTests {

    private let web = ContainerItem.stub(id: "web-frontend", image: "docker.io/library/nginx:1.27", status: .running)
    private let db = ContainerItem.stub(id: "database", image: "docker.io/library/postgres:16", status: .stopped)

    @Test func anEmptyQueryKeepsEverything() {
        #expect([web, db].matching("").count == 2)
        #expect([web, db].matching("   ").count == 2)
    }

    @Test func matchesOnNameAndOnImage() {
        #expect([web, db].matching("front").map(\.id) == ["web-frontend"])
        #expect([web, db].matching("postgres").map(\.id) == ["database"])
    }

    /// Typing the state is the first thing people try as a filter.
    @Test func matchesOnStatus() {
        #expect([web, db].matching("running").map(\.id) == ["web-frontend"])
    }

    /// Every word has to land somewhere, but not in the same field and not in
    /// the order they were typed — otherwise the user has to know which column
    /// holds what.
    @Test func everyTermMustMatchSomewhereInAnyOrder() {
        #expect([web, db].matching("nginx web").map(\.id) == ["web-frontend"])
        #expect([web, db].matching("web nginx").map(\.id) == ["web-frontend"])
        #expect([web, db].matching("nginx database").isEmpty)
    }

    @Test func caseDoesNotMatter() {
        #expect([web].matching("NGINX").count == 1)
    }

    /// `café` and `cafe` are the same image to everyone but a byte comparison.
    @Test func diacriticsDoNotMatter() {
        let item = ImageItem.stub(reference: "registry.local/cafe:1")
        #expect([item].matching("café").count == 1)
    }

    @Test func aPortIsFoundByEitherSideOfTheMapping() {
        let published = ContainerItem.stub(
            id: "web",
            ports: [PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, networkProtocol: "tcp")]
        )
        #expect([published].matching("8080").count == 1)
        #expect([published].matching("80").count == 1)
    }

    @Test func imagesMatchOnRepositoryTagAndDigest() {
        let image = ImageItem.stub(reference: "docker.io/library/alpine:3.20", digest: "sha256:abc123")
        #expect([image].matching("alpine").count == 1)
        #expect([image].matching("3.20").count == 1)
        #expect([image].matching("abc123").count == 1)
        #expect([image].matching("nginx").isEmpty)
    }

    @Test func volumesMatchOnNameAndDriver() {
        let volume = VolumeItem.stub(name: "pgdata")
        #expect([volume].matching("pgdata").count == 1)
        #expect([volume].matching("local").count == 1)
    }

    @Test func networksMatchOnNameAndSubnet() {
        let network = NetworkItem.stub(name: "backend")
        #expect([network].matching("backend").count == 1)
        #expect([network].matching("192.168").count == 1)
    }

    /// Untagged images sorting to the top would push the ones people recognise
    /// off the first screen.
    @Test func untaggedImagesSortLast() {
        let tagged = ImageItem.stub(displayReference: "alpine:3.20")
        // What an image that has been untagged, or only ever referenced by
        // digest, looks like in the list.
        let untagged = ImageItem.stub(displayReference: "alpine@sha256:abc")
        #expect(untagged.sortableTag > tagged.sortableTag)
    }

    @Test func containersThatNeverRanSortAsOldest() {
        let never = ContainerItem.stub(id: "new", status: .stopped)
        let ran = ContainerItem.stub(id: "old", startedAt: Date(timeIntervalSince1970: 1))
        #expect(never.sortableStartDate < ran.sortableStartDate)
    }
}
