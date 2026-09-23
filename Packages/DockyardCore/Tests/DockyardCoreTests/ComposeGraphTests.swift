import Foundation
import Testing

@testable import DockyardCore

@Suite struct ComposeGraphTests {

    private func services(_ edges: [String: [String]]) -> [ComposeService] {
        edges.map { name, dependencies in
            var service = ComposeService(name: name, image: "alpine")
            service.dependsOn = dependencies
            return service
        }
    }

    private func order(_ edges: [String: [String]]) throws -> [String] {
        try ComposeGraph.startOrder(services(edges)).get()
    }

    @Test func aDependencyStartsFirst() throws {
        #expect(try order(["web": ["db"], "db": []]) == ["db", "web"])
    }

    @Test func aChainStartsInOrder() throws {
        #expect(try order(["web": ["api"], "api": ["db"], "db": []]) == ["db", "api", "web"])
    }

    @Test func independentServicesComeBackAlphabetically() throws {
        #expect(try order(["zebra": [], "alpha": [], "middle": []]) == ["alpha", "middle", "zebra"])
    }

    /// Ties broken by name, not by dictionary iteration order. A start order
    /// that varies between runs turns an intermittent race into one nobody can
    /// reproduce.
    @Test func theOrderIsTheSameEveryTime() throws {
        let edges = ["web": ["db", "cache"], "db": [], "cache": [], "worker": ["db"]]
        let first = try order(edges)
        for _ in 0..<50 {
            #expect(try order(edges) == first)
        }
        #expect(first == ["cache", "db", "web", "worker"])
    }

    @Test func stopOrderIsTheReverse() throws {
        let list = services(["web": ["db"], "db": []])
        #expect(try ComposeGraph.stopOrder(list).get() == ["web", "db"])
    }

    /// "There is a cycle somewhere" is not a fixable message.
    @Test func aCycleIsNamedInFull() {
        let result = ComposeGraph.startOrder(services(["web": ["api"], "api": ["db"], "db": ["web"]]))
        guard case .failure(.cycle(let members)) = result else {
            Issue.record("expected a cycle, got \(result)")
            return
        }
        #expect(Set(members) == ["web", "api", "db"])
        let message = ComposeGraph.Problem.cycle(members).message
        for name in ["web", "api", "db"] {
            #expect(message.contains(name))
        }
        // Closes the loop, so it reads as a cycle rather than a list.
        #expect(message.hasSuffix("\(members[0])."))
    }

    @Test func aServiceDependingOnItselfIsACycle() {
        let result = ComposeGraph.startOrder(services(["web": ["web"]]))
        guard case .failure(.cycle(let members)) = result else {
            Issue.record("expected a cycle, got \(result)")
            return
        }
        #expect(members == ["web"])
    }

    /// Only the services actually in the loop, not every unplaced one.
    @Test func aCycleNamesOnlyItsOwnMembers() {
        let result = ComposeGraph.startOrder(
            services(["a": ["b"], "b": ["a"], "downstream": ["a"], "free": []])
        )
        guard case .failure(.cycle(let members)) = result else {
            Issue.record("expected a cycle, got \(result)")
            return
        }
        #expect(Set(members) == ["a", "b"])
        #expect(!members.contains("downstream"))
    }

    @Test func aDependencyOnSomethingUndefinedNamesBoth() {
        let result = ComposeGraph.startOrder(services(["web": ["nope"]]))
        guard case .failure(.unknownDependency(let service, let missing)) = result else {
            Issue.record("expected an unknown dependency, got \(result)")
            return
        }
        #expect(service == "web")
        #expect(missing == "nope")
        let message = ComposeGraph.Problem.unknownDependency(service: service, missing: missing).message
        #expect(message.contains("web") && message.contains("nope"))
    }

    @Test func anEmptyFileHasAnEmptyOrder() throws {
        #expect(try ComposeGraph.startOrder([]).get().isEmpty)
    }
}
