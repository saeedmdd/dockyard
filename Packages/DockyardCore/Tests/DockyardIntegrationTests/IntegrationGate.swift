import Foundation
import Testing

@testable import DockyardCore

/// Integration tests run only against a real, running `container-apiserver`, so
/// they are opt-in: `DOCKYARD_INTEGRATION=1 swift test --filter DockyardIntegrationTests`.
/// Without the variable the suite is skipped, never failed, so `swift test` stays
/// green anywhere. Filled in by T12.
enum IntegrationGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DOCKYARD_INTEGRATION"] == "1"
    }
}

@Suite(.enabled(if: IntegrationGate.isEnabled))
struct IntegrationSmokeTests {
    @Test func gateIsOn() {
        #expect(IntegrationGate.isEnabled)
    }
}
