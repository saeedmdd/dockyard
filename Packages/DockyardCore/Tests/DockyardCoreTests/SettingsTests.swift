import Foundation
import Testing

@testable import DockyardCore

/// Preferences, and the two things that read them.
@MainActor
@Suite struct SettingsTests {

    /// A scratch defaults domain, so a test run never touches the developer's
    /// own preferences.
    private func makeDefaults() -> UserDefaults {
        let suite = "dockyard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsAreTheOnesTheAppShipsWith() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.pollIntervalSeconds == 2)
        #expect(settings.pollInterval == .seconds(2))
        #expect(!settings.showsInfrastructureImages)
        #expect(!settings.startsHidden)
        #expect(settings.defaultPlatform.isEmpty)
        #expect(settings.resolvedCLIPath == AppSettings.defaultCLIPath)
    }

    @Test func valuesSurviveARelaunch() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.pollIntervalSeconds = 5
        first.showsInfrastructureImages = true
        first.defaultPlatform = "linux/amd64"
        first.cliPath = "/opt/homebrew/bin/container"

        let second = AppSettings(defaults: defaults)
        #expect(second.pollIntervalSeconds == 5)
        #expect(second.showsInfrastructureImages)
        #expect(second.defaultPlatform == "linux/amd64")
        #expect(second.resolvedCLIPath == "/opt/homebrew/bin/container")
    }

    /// A hand-edited plist should not be able to put the app somewhere its own
    /// UI cannot: a tenth of a second would hammer the daemon, an hour would
    /// look frozen.
    @Test func thePollIntervalIsClampedComingAndGoing() {
        let defaults = makeDefaults()
        defaults.set(0.05, forKey: AppSettings.Key.pollInterval)
        #expect(AppSettings(defaults: defaults).pollIntervalSeconds == 1)

        defaults.set(3600.0, forKey: AppSettings.Key.pollInterval)
        #expect(AppSettings(defaults: defaults).pollIntervalSeconds == 10)

        let settings = AppSettings(defaults: makeDefaults())
        settings.pollIntervalSeconds = 99
        #expect(settings.pollIntervalSeconds == 10)
    }

    /// A NaN written into defaults would propagate into a `Duration` and crash
    /// the poller rather than the settings window.
    @Test func anUnusableIntervalFallsBackToTheDefault() {
        #expect(AppSettings.clampInterval(.nan) == 2)
    }

    @Test func changingTheIntervalTellsWhoeverIsListening() {
        let settings = AppSettings(defaults: makeDefaults())
        var reported: Duration?
        settings.onPollIntervalChange = { reported = $0 }

        settings.pollIntervalSeconds = 7

        #expect(reported == .seconds(7))
    }

    /// The clamp reports the value that was actually stored, not the one asked
    /// for, or the poller would be retimed to something the settings do not
    /// hold.
    @Test func aClampedIntervalReportsTheClampedValue() {
        let settings = AppSettings(defaults: makeDefaults())
        var reported: [Duration] = []
        settings.onPollIntervalChange = { reported.append($0) }

        settings.pollIntervalSeconds = 40

        #expect(reported == [.seconds(10)])
    }

    @Test func showingInfrastructureImagesTellsWhoeverIsListening() {
        let settings = AppSettings(defaults: makeDefaults())
        var reported: Bool?
        settings.onShowInfrastructureChange = { reported = $0 }

        settings.showsInfrastructureImages = true

        #expect(reported == true)
    }

    /// Blanking the field means "use the default", not "point at nothing".
    @Test func anEmptyCLIPathFallsBackToTheInstallLocation() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.cliPath = "/somewhere/else"
        settings.cliPath = ""
        #expect(settings.resolvedCLIPath == AppSettings.defaultCLIPath)
    }

    /// A path pasted from a terminal usually arrives with a newline on it.
    @Test func theCLIPathIsTrimmed() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.cliPath = "  /usr/local/bin/container\n"
        #expect(settings.cliPath == "/usr/local/bin/container")
    }

    // MARK: - Sort persistence

    @Test func eachTableRemembersItsOwnSort() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.setSort(.init(column: "image", isAscending: false), for: .containers)
        settings.setSort(.init(column: "tag", isAscending: true), for: .images)

        #expect(settings.sort(for: .containers) == .init(column: "image", isAscending: false))
        #expect(settings.sort(for: .images) == .init(column: "tag", isAscending: true))
        #expect(settings.sort(for: .volumes) == nil)
    }

    @Test func aSortCanBeForgotten() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.setSort(.init(column: "name", isAscending: true), for: .volumes)
        settings.setSort(nil, for: .volumes)
        #expect(settings.sort(for: .volumes) == nil)
    }

    @Test func sortsSurviveARelaunch() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults)
            .setSort(.init(column: "started", isAscending: false), for: .containers)
        #expect(
            AppSettings(defaults: defaults).sort(for: .containers)
                == .init(column: "started", isAscending: false)
        )
    }
}

/// The login-item toggle, without registering anything on the machine running
/// the tests.
@MainActor
@Suite struct LoginItemTests {

    final class FakeService: LoginItemService {
        var state: LoginItem.State
        var failure: (any Error)?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0

        init(state: LoginItem.State = .disabled) {
            self.state = state
        }

        func currentState() -> LoginItem.State { state }

        func register() throws {
            registerCount += 1
            if let failure { throw failure }
            state = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            if let failure { throw failure }
            state = .disabled
        }
    }

    @Test func enablingRegistersAndReadsBack() {
        let service = FakeService()
        let item = LoginItem(service: service)

        #expect(item.setEnabled(true))
        #expect(service.registerCount == 1)
        #expect(item.state == .enabled)
        #expect(item.lastError == nil)
    }

    @Test func disablingUnregisters() {
        let service = FakeService(state: .enabled)
        let item = LoginItem(service: service)

        #expect(item.setEnabled(false))
        #expect(service.unregisterCount == 1)
        #expect(item.state == .disabled)
    }

    /// A toggle that springs back with no explanation is the thing to avoid.
    @Test func aRefusalIsReportedAndTheStateIsNotClaimed() {
        let service = FakeService()
        service.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let item = LoginItem(service: service)

        #expect(!item.setEnabled(true))
        #expect(item.state == .disabled)
        #expect(item.lastError?.contains("/Applications") == true)
    }

    /// The system records registration asynchronously, so reading the status
    /// straight back can still say "not registered" for a moment.
    @Test func aSuccessfulRegisterIsTrustedOverALaggingStatus() {
        final class LaggingService: LoginItemService {
            func currentState() -> LoginItem.State { .disabled }
            func register() throws {}
            func unregister() throws {}
        }
        let item = LoginItem(service: LaggingService())

        #expect(item.setEnabled(true))
        #expect(item.state == .enabled)
    }

    /// `SMAppService` reports `notFound` for an app that has simply never been
    /// registered, including one sitting in /Applications that would register
    /// fine. Presenting that as unavailable put a dead-end message beside a
    /// toggle that worked.
    @Test func neverRegisteredIsOfferedAsAnOrdinaryOffState() {
        let item = LoginItem(service: FakeService(state: .disabled))
        #expect(item.state == .disabled)
        #expect(!item.state.isEnabled)
        #expect(item.lastError == nil)
    }

    /// Once the user turns it off in System Settings, the app cannot turn it
    /// back on and has to say so.
    @Test func approvalRequiredIsItsOwnState() {
        let item = LoginItem(service: FakeService(state: .blockedBySystemSettings))
        #expect(item.state == .blockedBySystemSettings)
        #expect(!item.state.isEnabled)
    }

    @Test func anOrdinaryFailureKeepsItsMessage() {
        let message = LoginItem.explain(
            NSError(domain: "Whatever", code: 7, userInfo: [NSLocalizedDescriptionKey: "disk full"]),
            enabling: false
        )
        #expect(message.contains("remove Dockyard from your login items"))
        #expect(message.contains("disk full"))
    }
}
