import Foundation
import Testing

@testable import DockyardCore

/// The state machine is a pure function of three reads, so none of this touches
/// `/etc`, the daemon, or the real home directory.
@Suite struct ComposeDNSStateTests {

    @Test func nothingAnywhereIsNotConfigured() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: nil, resolverDomains: [], onDiskDomain: nil)
                == .notConfigured
        )
    }

    /// The daemon only copies the configuration when it starts, so a domain on
    /// disk that it has not picked up needs a restart, not more editing.
    @Test func writtenButNotPickedUpAsksForARestart() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: nil, resolverDomains: [], onDiskDomain: "test")
                == .restartPending(domain: "test")
        )
    }

    /// The half that matters for compose: containers can resolve each other
    /// even though this Mac cannot resolve them.
    @Test func aliveWithoutAHostResolverStillLetsContainersTalk() {
        let state = ComposeDNSSetup.state(effectiveDomain: "test", resolverDomains: [], onDiskDomain: "test")
        #expect(state == .hostResolverMissing(domain: "test"))
        #expect(state.containersCanResolveEachOther)
    }

    @Test func bothHalvesPresentIsReady() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: "test", resolverDomains: ["test"], onDiskDomain: "test")
                == .ready(domain: "test")
        )
    }

    /// The resolver files are sometimes reported with a trailing dot.
    @Test func aTrailingDotOnTheResolverEntryStillCounts() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: "test", resolverDomains: ["test."], onDiskDomain: "test")
                == .ready(domain: "test")
        )
    }

    @Test func aResolverForADifferentDomainDoesNotCount() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: "test", resolverDomains: ["other"], onDiskDomain: "test")
                == .hostResolverMissing(domain: "test")
        )
    }

    /// An unset domain reaches us as an empty string in some configurations.
    @Test func anEmptyDomainCountsAsUnset() {
        #expect(
            ComposeDNSSetup.state(effectiveDomain: "", resolverDomains: [], onDiskDomain: "")
                == .notConfigured
        )
    }

    @Test func onlyTheUnconfiguredStatesBlockContainersTalking() {
        #expect(!ComposeDNSState.notConfigured.containersCanResolveEachOther)
        #expect(!ComposeDNSState.restartPending(domain: "test").containersCanResolveEachOther)
        #expect(ComposeDNSState.hostResolverMissing(domain: "test").containersCanResolveEachOther)
        #expect(ComposeDNSState.ready(domain: "test").containersCanResolveEachOther)
    }
}

@Suite struct ComposeDNSValidationTests {

    @Test(arguments: ["test", "dev", "lab", "a", "my-lab", "x1"])
    func acceptsPlainLabels(_ domain: String) {
        #expect(ComposeDNSSetup.validate(domain: domain) == nil, "\(domain)")
    }

    /// `.local` is Bonjour's. Taking it over breaks printers, AirPlay and every
    /// other device on the network.
    @Test func refusesLocalByName() {
        let reason = ComposeDNSSetup.validate(domain: "local")
        #expect(reason?.contains("Bonjour") == true)
    }

    @Test(arguments: ["my.lab", "example.com", "a.b.c"])
    func refusesAnythingWithADot(_ domain: String) {
        #expect(ComposeDNSSetup.validate(domain: domain)?.contains("no dots") == true)
    }

    @Test(arguments: ["", "1lab", "-lab", "LAB", "lab_x", "lab space", String(repeating: "a", count: 40)])
    func refusesAnythingThatIsNotADNSLabel(_ domain: String) {
        #expect(ComposeDNSSetup.validate(domain: domain) != nil, "\(domain)")
    }
}

@Suite struct ComposeDNSConfigTests {

    private func withFile(_ contents: String?, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-dns-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        try body(url)
    }

    @Test func readsTheDomainOutOfTheDNSTable() {
        let toml = """
            [build]
            cpus = 2

            [dns]
            domain = "lab"
            """
        #expect(ComposeDNSSetup.domain(inTOML: toml) == "lab")
    }

    /// A `domain` key in a different table is not ours.
    @Test func ignoresADomainKeyInAnotherTable() {
        #expect(ComposeDNSSetup.domain(inTOML: "[registry]\ndomain = \"nope\"\n") == nil)
    }

    @Test func anEmptyDNSTableHasNoDomain() {
        #expect(ComposeDNSSetup.domain(inTOML: "[dns]\n\n[kernel]\n") == nil)
        #expect(ComposeDNSSetup.hasDNSTable(inTOML: "[dns]\n"))
    }

    @Test func aMissingFileIsCreated() throws {
        try withFile(nil) { url in
            let edit = ComposeDNSSetup.plannedEdit(domain: "lab", at: url)
            guard case .create(_, let contents) = edit else {
                Issue.record("expected a create, got \(edit)")
                return
            }
            #expect(contents.contains("[dns]"))
            try ComposeDNSSetup.apply(edit)
            #expect(ComposeDNSSetup.onDiskDomain(at: url) == "lab")
        }
    }

    /// Appending a new table at the end cannot change the meaning of an
    /// existing one, which is why it is done this way and not by re-emitting
    /// the document.
    @Test func afileWithoutADNSTableIsAppendedToAfterABackup() throws {
        try withFile("[build]\ncpus = 2\n") { url in
            let edit = ComposeDNSSetup.plannedEdit(domain: "lab", at: url)
            guard case .append = edit else {
                Issue.record("expected an append, got \(edit)")
                return
            }
            let backup = try ComposeDNSSetup.apply(edit)

            #expect(ComposeDNSSetup.onDiskDomain(at: url) == "lab")
            // The original settings survive, byte for byte, at the top.
            let after = try String(contentsOf: url, encoding: .utf8)
            #expect(after.hasPrefix("[build]\ncpus = 2\n"))
            let saved = try String(contentsOf: try #require(backup), encoding: .utf8)
            #expect(saved == "[build]\ncpus = 2\n")
        }
    }

    /// Machine-editing somebody's hand-written configuration is not worth the
    /// one branch it saves.
    @Test func afileThatAlreadyHasADNSTableIsRefused() throws {
        try withFile("[dns]\ndomain = \"mine\"\n") { url in
            let edit = ComposeDNSSetup.plannedEdit(domain: "lab", at: url)
            #expect(edit.isRefusal)
            #expect(throws: DockyardError.self) { try ComposeDNSSetup.apply(edit) }
            // Untouched.
            #expect(ComposeDNSSetup.onDiskDomain(at: url) == "mine")
        }
    }
}

/// The escalation is built and quoted here, and asserted **without running it**
/// — a test that triggered a real authorization prompt would be unrunnable.
@Suite struct ComposeDNSPrivilegeTests {

    @Test func buildsTheCommandTheUserIsShown() {
        let command = ComposeDNSSetup.privilegedCommand(cliPath: "/usr/local/bin/container", domain: "test")
        #expect(command == "'/usr/local/bin/container' system dns create 'test'")
    }

    /// A path with a space or a quote in it must not break out of the command.
    @Test func quotesAwkwardPaths() {
        let command = ComposeDNSSetup.privilegedCommand(
            cliPath: "/Users/me/my tools/container", domain: "test"
        )
        #expect(command.contains("'/Users/me/my tools/container'"))

        // A single quote closes the quoting, escapes a literal one, and reopens.
        let nasty = ComposeDNSSetup.shellQuoted("/tmp/it's here")
        #expect(nasty == #"'/tmp/it'\''s here'"#)
    }

    @Test func wrapsTheCommandForAppleScript() {
        let script = ComposeDNSSetup.appleScript(
            forPrivileged: "'/usr/local/bin/container' system dns create 'test'"
        )
        #expect(script.hasPrefix("do shell script \""))
        #expect(script.hasSuffix("with administrator privileges"))
        #expect(script.contains("system dns create"))
    }

    @Test func escapesQuotesAndBackslashesForAppleScript() {
        #expect(ComposeDNSSetup.appleScriptEscaped(#"a"b"#) == #"a\"b"#)
        #expect(ComposeDNSSetup.appleScriptEscaped(#"a\b"#) == #"a\\b"#)
    }
}
