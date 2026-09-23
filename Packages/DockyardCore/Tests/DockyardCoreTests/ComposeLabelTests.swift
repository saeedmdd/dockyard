import Foundation
import Testing

@testable import DockyardCore

/// How a project's containers are found again after the app restarts.
@Suite struct ComposeLabelTests {

    @Test func aProjectFilterSelectsItsOwnLabel() {
        let filter = ComposeLabels.filter(project: "shop")
        #expect(filter == [ComposeLabels.project: "^shop$"])
    }

    /// Upstream matches label values as regular expressions, so an unescaped
    /// project name is a pattern. `.` is the one that bites: `my.proj` would
    /// otherwise match `myXproj`, and `down` deletes whatever the filter
    /// returns.
    @Test(arguments: [
        "my.proj", "a+b", "web(1)", "cache[0]", "a|b", "v1.2.3", "x*y", "^start", "end$",
    ])
    func metacharactersInAProjectNameAreEscaped(_ name: String) throws {
        let pattern = ComposeLabels.exactly(name)
        let regex = try NSRegularExpression(pattern: pattern)

        func matches(_ candidate: String) -> Bool {
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, range: range) != nil
        }

        #expect(matches(name), "a project must match its own name")
        // What the metacharacter would have matched had it not been escaped.
        let impostor = name.replacingOccurrences(of: ".", with: "X")
            .replacingOccurrences(of: "+", with: "bb")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "$", with: "")
        if impostor != name {
            #expect(!matches(impostor), "“\(impostor)” must not match the filter for “\(name)”")
        }
    }

    @Test func theFilterIsAnchoredAtBothEnds() throws {
        let regex = try NSRegularExpression(pattern: ComposeLabels.exactly("shop"))
        for candidate in ["shop-staging", "my-shop", "shopping", "", "SHOP"] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            #expect(regex.firstMatch(in: candidate, range: range) == nil, "“\(candidate)” must not match")
        }
    }

    @Test func labelsCarryEverythingNeededToRebuildAProjectWithoutTheFile() {
        let labels = ComposeLabels.labels(
            project: "shop",
            service: "web",
            file: URL(fileURLWithPath: "/Users/me/shop/compose.yaml"),
            configHash: "abc123",
            dependsOn: ["redis", "db"],
            restart: "always"
        )

        #expect(labels[ComposeLabels.project] == "shop")
        #expect(labels[ComposeLabels.service] == "web")
        #expect(labels[ComposeLabels.file] == "/Users/me/shop/compose.yaml")
        #expect(labels[ComposeLabels.workdir] == "/Users/me/shop")
        #expect(labels[ComposeLabels.configHash] == "abc123")
        // Sorted, so the same dependencies always produce the same label and a
        // reordered compose file does not look like a changed one.
        #expect(labels[ComposeLabels.dependsOn] == "db,redis")
        #expect(labels[ComposeLabels.restart] == "always")
        #expect(labels[ComposeLabels.schema] == ComposeLabels.schemaVersion)
    }
}

/// The backend filter itself, through the mock's real regex evaluation.
@Suite struct ComposeContainerFilterTests {

    private func backend() -> MockBackend {
        MockBackend(containers: [
            .stub(id: "shop-web", labels: [ComposeLabels.project: "shop", ComposeLabels.service: "web"]),
            .stub(id: "shop-db", labels: [ComposeLabels.project: "shop", ComposeLabels.service: "db"]),
            .stub(id: "blog-web", labels: [ComposeLabels.project: "blog", ComposeLabels.service: "web"]),
            .stub(id: "unlabelled"),
        ])
    }

    @Test func aProjectSeesOnlyItsOwnContainers() async throws {
        let listed = try await backend().listContainers(matchingLabels: ComposeLabels.filter(project: "shop"))
        #expect(listed.map(\.id) == ["shop-db", "shop-web"])
    }

    /// A container with no project label must not be swept up by a project's
    /// teardown. The runtime matches a missing label as the empty string, which
    /// an anchored pattern rejects.
    @Test func containersWithNoProjectLabelAreExcluded() async throws {
        let listed = try await backend().listContainers(matchingLabels: ComposeLabels.filter(project: "shop"))
        #expect(!listed.contains { $0.id == "unlabelled" })
    }

    /// The blast-radius test. If `exactly(_:)` ever stops escaping, `down` on
    /// `my.proj` takes `myXproj` and `my.proj.staging` with it.
    @Test func aProjectWithRegexCharactersTakesOnlyItsOwn() async throws {
        let backend = MockBackend(containers: [
            .stub(id: "real-web", labels: [ComposeLabels.project: "my.proj"]),
            .stub(id: "real-db", labels: [ComposeLabels.project: "my.proj"]),
            .stub(id: "impostor", labels: [ComposeLabels.project: "myXproj"]),
            .stub(id: "sibling", labels: [ComposeLabels.project: "my.proj.staging"]),
            .stub(id: "bystander"),
        ])

        let listed = try await backend.listContainers(matchingLabels: ComposeLabels.filter(project: "my.proj"))

        #expect(listed.map(\.id).sorted() == ["real-db", "real-web"])
    }

    @Test func aFilterWithSeveralLabelsRequiresAllOfThem() async throws {
        let listed = try await backend().listContainers(matchingLabels: [
            ComposeLabels.project: ComposeLabels.exactly("shop"),
            ComposeLabels.service: ComposeLabels.exactly("db"),
        ])
        #expect(listed.map(\.id) == ["shop-db"])
    }
}
