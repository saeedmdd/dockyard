import Foundation
import Testing

@testable import DockyardCore

@Suite struct RegistryCredentialsTests {

    @Test func allThreeFieldsAreRequired() {
        var credentials = RegistryCredentials()
        #expect(!credentials.isValid)
        #expect(credentials.validationProblems.count == 3)

        credentials.hostname = "ghcr.io"
        credentials.username = "me"
        credentials.password = "token"
        #expect(credentials.isValid)
    }

    @Test func whitespaceIsTrimmedFromHostAndUser() {
        var credentials = RegistryCredentials()
        credentials.hostname = "  ghcr.io  "
        credentials.username = " me "
        credentials.password = "token"

        #expect(credentials.trimmedHostname == "ghcr.io")
        #expect(credentials.trimmedUsername == "me")
        #expect(credentials.isValid)
    }

    /// A password of only spaces is a real password; it must not be trimmed
    /// away into nothing.
    @Test func passwordIsNotTrimmed() {
        var credentials = RegistryCredentials()
        credentials.hostname = "ghcr.io"
        credentials.username = "me"
        credentials.password = "  "
        #expect(credentials.isValid, "a password of spaces is still a password")
    }
}

@MainActor
@Suite struct RegistryStoreTests {

    private func store(_ logins: [RegistryLogin] = []) -> (RegistryStore, MockBackend) {
        let backend = MockBackend()
        backend.setLogins(logins)
        return (RegistryStore(backend: backend), backend)
    }

    private func credentials(host: String = "ghcr.io") -> RegistryCredentials {
        var credentials = RegistryCredentials()
        credentials.hostname = host
        credentials.username = "me"
        credentials.password = "token"
        return credentials
    }

    @Test func loginAddsARegistry() async {
        let (store, backend) = store()

        let ok = await store.logIn(credentials())

        #expect(ok)
        #expect(backend.calls.logIn == 1)
        #expect(store.logins.map(\.hostname) == ["ghcr.io"])
        #expect(store.statusNote?.contains("ghcr.io") == true)
    }

    /// Signing in again to the same registry replaces the credential rather
    /// than adding a second row for it.
    @Test func loggingInTwiceReplacesTheEntry() async {
        let (store, _) = store()

        await store.logIn(credentials())
        await store.logIn(credentials())

        #expect(store.logins.count == 1)
    }

    @Test func failedLoginIsReportedAndNothingIsStored() async {
        let (store, backend) = store()
        backend.setFailure(.upstream(code: "unauthorized", message: "bad credentials"))

        let ok = await store.logIn(credentials())

        #expect(!ok)
        #expect(store.actionError == .upstream(code: "unauthorized", message: "bad credentials"))
        #expect(store.logins.isEmpty, "a rejected login must not be saved")
    }

    @Test func logoutRemovesARegistry() async {
        let (store, _) = store()
        await store.logIn(credentials())

        #expect(store.logOut(hostname: "ghcr.io"))
        #expect(store.logins.isEmpty)
    }

    @Test func loggingOutOfSomethingUnknownIsReported() {
        let (store, _) = store()
        store.refreshLogins()

        #expect(!store.logOut(hostname: "never.example"))
        #expect(store.actionError != nil)
    }

    @Test func loginsAreListedSorted() {
        let (store, _) = store([
            RegistryLogin(hostname: "zebra.io", username: "a", createdAt: Date(), modifiedAt: Date()),
            RegistryLogin(hostname: "alpha.io", username: "b", createdAt: Date(), modifiedAt: Date()),
        ])

        store.refreshLogins()

        #expect(store.logins.map(\.hostname) == ["alpha.io", "zebra.io"])
    }

    // MARK: - Push

    @Test func pushReportsSuccess() async {
        let (store, backend) = store()
        var progress = PullProgress()
        progress.apply([.description("Pushing image"), .setTotalSize(100), .setSize(100)])
        backend.setPullProgress([progress])

        let job = store.push(reference: "ghcr.io/me/app:1")
        await store.settlePushes()

        #expect(job.state == .succeeded)
        #expect(backend.calls.push == 1)
    }

    @Test func failedPushKeepsTheError() async {
        let (store, backend) = store()
        backend.setPullFailure(.upstream(code: "unauthorized", message: "denied"))

        let job = store.push(reference: "ghcr.io/me/app:1")
        await store.settlePushes()

        #expect(job.state == .failed(.upstream(code: "unauthorized", message: "denied")))
    }

    /// Same trap as pull and build: a cancelled stream finishes rather than
    /// throwing, so success must not be inferred from the loop ending.
    @Test func cancelledPushIsNotReportedAsSuccess() async {
        let (store, backend) = store()
        backend.setPullProgress(Array(repeating: PullProgress(), count: 200))

        let job = store.push(reference: "ghcr.io/me/app:1")
        try? await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await store.settlePushes()

        #expect(job.state == .cancelled)
        #expect(job.state != .succeeded)
    }

    // MARK: - Archives

    @Test func saveWritesAnArchiveAndSaysSo() async {
        let (store, backend) = store()
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dockyard-save-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: destination) }

        let ok = await store.save(references: ["alpine:3.20"], to: destination)

        #expect(ok)
        #expect(backend.calls.saveImages == 1)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(store.statusNote?.contains(destination.lastPathComponent) == true)
    }

    @Test func loadReportsWhatItFound() async {
        let (store, backend) = store()
        backend.setLoadResult(["docker.io/library/alpine:3.20"])

        let loaded = await store.load(from: URL(fileURLWithPath: "/tmp/whatever.tar"))

        #expect(loaded == ["docker.io/library/alpine:3.20"])
        #expect(store.statusNote?.contains("alpine") == true)
    }

    /// An archive with nothing usable in it should say so rather than look
    /// like a success with no effect.
    @Test func loadingAnEmptyArchiveSaysSo() async {
        let (store, _) = store()

        let loaded = await store.load(from: URL(fileURLWithPath: "/tmp/empty.tar"))

        #expect(loaded.isEmpty)
        #expect(store.statusNote?.contains("No images") == true)
    }

    @Test func failedLoadIsReported() async {
        let (store, backend) = store()
        backend.setFailure(.upstream(code: "invalidArgument", message: "not a tar archive"))

        let loaded = await store.load(from: URL(fileURLWithPath: "/tmp/bad.tar"))

        #expect(loaded.isEmpty)
        #expect(store.actionError != nil)
    }
}
