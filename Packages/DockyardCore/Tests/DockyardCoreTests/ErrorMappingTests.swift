import ContainerizationError
import Foundation
import Testing

@testable import DockyardCore

/// The mapping that decides whether the app shows a per-row error or the
/// daemon-down screen. Getting this wrong means a stopped daemon looks like a
/// broken container, so the real upstream error shapes are reproduced here.
@Suite struct ErrorMappingTests {

    /// Exactly what `ContainerClient.list` throws when the apiserver is not
    /// running, as seen from `container list` on a machine with the daemon
    /// stopped:
    /// `internalError: "failed to list containers" (cause: "interrupted: "XPC connection error: Connection invalid"")`
    @Test func daemonDownIsDetectedThroughTheCauseChain() {
        let underlying = ContainerizationError(
            .interrupted,
            message: "XPC connection error: Connection invalid"
        )
        let wrapped = ContainerizationError(
            .internalError,
            message: "failed to list containers",
            cause: underlying
        )

        let mapped = DockyardError(mapping: wrapped)

        #expect(mapped.isDaemonDown)
        #expect(mapped == .daemonUnreachable("XPC connection error: Connection invalid"))
    }

    @Test func xpcTimeoutMapsToDaemonTimeout() {
        let error = ContainerizationError(
            .internalError,
            message: "XPC timeout for request to com.apple.container.apiserver/ping"
        )

        let mapped = DockyardError(mapping: error)

        #expect(mapped.isDaemonDown)
        if case .daemonTimeout = mapped {} else {
            Issue.record("expected .daemonTimeout, got \(mapped)")
        }
    }

    /// A genuine runtime rejection must stay a per-row error, otherwise one bad
    /// container would send the whole window to the onboarding screen.
    @Test func runtimeRejectionIsNotTreatedAsDaemonDown() {
        let error = ContainerizationError(
            .invalidArgument,
            message: "mount source path '/missing' does not exist"
        )

        let mapped = DockyardError(mapping: error)

        #expect(!mapped.isDaemonDown)
        #expect(mapped == .upstream(code: "invalidArgument", message: "mount source path '/missing' does not exist"))
    }

    /// The outer message is generic; the inner one says what actually happened.
    @Test func innermostMessageIsSurfaced() {
        let error = ContainerizationError(
            .internalError,
            message: "failed to create container",
            cause: ContainerizationError(.exists, message: "container with id \"web\" already exists")
        )

        let mapped = DockyardError(mapping: error)

        #expect(mapped == .upstream(code: "internalError", message: "container with id \"web\" already exists"))
    }

    @Test func unknownErrorsFallBackToOther() {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        #expect(DockyardError(mapping: Boom()) == .other("boom"))
    }

    @Test func alreadyMappedErrorsPassThroughUnchanged() {
        let original = DockyardError.cliMissing(path: "/usr/local/bin/container")
        #expect(DockyardError(mapping: original) == original)
    }

    /// The mapper walks `cause` chains, so a deep one must terminate rather than
    /// spin. 32 levels exceeds the mapper's bound of 16.
    @Test func deepCauseChainTerminates() {
        var error = ContainerizationError(.internalError, message: "level 0")
        for level in 1...32 {
            error = ContainerizationError(.internalError, message: "level \(level)", cause: error)
        }

        let mapped = DockyardError(mapping: error)

        #expect(!mapped.isDaemonDown)
        if case .upstream(let code, _) = mapped {
            #expect(code == "internalError")
        } else {
            Issue.record("expected .upstream, got \(mapped)")
        }
    }

    @Test func daemonDownErrorsCarryRecoveryGuidance() {
        let error = DockyardError.daemonUnreachable("XPC connection error: Connection invalid")
        #expect(error.errorDescription == "The container system is not running.")
        #expect(error.recoverySuggestion?.contains("container system start") == true)
    }
}
