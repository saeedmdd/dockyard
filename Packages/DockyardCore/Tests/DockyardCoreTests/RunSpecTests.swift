import Foundation
import Testing

@testable import DockyardCore

@Suite struct RunSpecCommandTests {

    /// `sh -c "echo hello world"` must reach the runtime as three arguments,
    /// not five — splitting naively on spaces would break every shell command
    /// anyone types into the sheet.
    @Test func quotedArgumentsStayTogether() {
        var spec = RunSpec(image: "alpine")
        spec.command = #"sh -c "echo hello world""#
        #expect(spec.commandArguments == ["sh", "-c", "echo hello world"])
    }

    @Test func singleQuotesWorkToo() {
        var spec = RunSpec(image: "alpine")
        spec.command = "sh -c 'ls -la /tmp'"
        #expect(spec.commandArguments == ["sh", "-c", "ls -la /tmp"])
    }

    @Test func extraWhitespaceIsIgnored() {
        var spec = RunSpec(image: "alpine")
        spec.command = "  sleep    600  "
        #expect(spec.commandArguments == ["sleep", "600"])
    }

    @Test func emptyCommandYieldsNoArguments() {
        #expect(RunSpec(image: "alpine").commandArguments.isEmpty)
    }

    /// An empty quoted string is a real argument, e.g. `sh -c ""`.
    @Test func emptyQuotedArgumentIsPreserved() {
        var spec = RunSpec(image: "alpine")
        spec.command = #"sh -c """#
        #expect(spec.commandArguments == ["sh", "-c", ""])
    }
}

@Suite struct RunSpecValidationTests {

    @Test func imageIsRequired() {
        let spec = RunSpec()
        #expect(!spec.isRunnable)
        #expect(spec.validationProblems.contains { $0.contains("image") })
    }

    @Test func aPlainImageIsRunnable() {
        #expect(RunSpec(image: "alpine:3.20").isRunnable)
    }

    /// Mirrors `ManagedContainer.nameValid`, which is what the runtime applies.
    @Test(arguments: ["web", "web-1", "my.app_2", "a1"])
    func validNamesAreAccepted(name: String) {
        var spec = RunSpec(image: "alpine")
        spec.name = name
        #expect(spec.isRunnable, "\(name) should be valid")
    }

    @Test(arguments: ["has space", "-leading", "_leading", "a", ""])
    func questionableNamesAreCaught(name: String) {
        var spec = RunSpec(image: "alpine")
        spec.name = name
        // A blank name is fine — the runtime mints one.
        if name.isEmpty {
            #expect(spec.isRunnable)
        } else {
            #expect(!spec.isRunnable, "\(name) should be rejected")
        }
    }

    @Test func cpusMustBeAWholeNumber() {
        var spec = RunSpec(image: "alpine")
        spec.cpus = "two"
        #expect(!spec.isRunnable)

        spec.cpus = "2"
        #expect(spec.isRunnable)
    }

    @Test(arguments: ["8080:80", "127.0.0.1:8080:80", "53:53/udp", "9200:9200/tcp"])
    func validPortMappingsAreAccepted(port: String) {
        var spec = RunSpec(image: "alpine")
        spec.publishedPorts = [port]
        #expect(spec.isRunnable, "\(port) should be valid")
    }

    @Test(arguments: ["8080", "8080:", "http:80", "8080:80/sctp"])
    func malformedPortMappingsAreCaught(port: String) {
        var spec = RunSpec(image: "alpine")
        spec.publishedPorts = [port]
        #expect(!spec.isRunnable, "\(port) should be rejected")
    }
}

@Suite struct RunSpecFlagsTests {

    private func spec() -> RunSpec {
        var spec = RunSpec(image: "docker.io/library/nginx:latest")
        spec.name = "web"
        spec.command = "nginx -g 'daemon off;'"
        spec.entrypoint = "/docker-entrypoint.sh"
        spec.workingDirectory = "/app"
        spec.user = "1000:1000"
        spec.environment = [.init(key: "GREETING", value: "hello"), .init(key: "QUERY", value: "a=1&b=2")]
        spec.publishedPorts = ["8080:80"]
        spec.volumes = ["/Users/test/site:/usr/share/nginx/html:ro"]
        spec.tmpfs = ["/run:64m"]
        spec.networks = ["default"]
        spec.cpus = "2"
        spec.memory = "512m"
        spec.shmSize = "64m"
        spec.labels = [.init(key: "app", value: "web")]
        spec.addedCapabilities = ["NET_ADMIN"]
        spec.droppedCapabilities = ["CHOWN"]
        spec.dnsNameservers = ["1.1.1.1"]
        spec.dnsDomain = "test"
        spec.dnsSearchDomains = ["svc.local"]
        spec.readOnlyRootFilesystem = true
        spec.removeWhenStopped = true
        spec.enableRosetta = true
        spec.allocateTerminal = true
        return spec
    }

    @Test func everyFieldReachesTheRightFlag() throws {
        let flags = try spec().toFlags()

        #expect(flags.process.env == ["GREETING=hello", "QUERY=a=1&b=2"])
        #expect(flags.process.user == "1000:1000")
        #expect(flags.process.cwd == "/app")
        #expect(flags.process.tty)

        #expect(flags.management.name == "web")
        #expect(flags.management.entrypoint == "/docker-entrypoint.sh")
        #expect(flags.management.publishPorts == ["8080:80"])
        #expect(flags.management.volumes == ["/Users/test/site:/usr/share/nginx/html:ro"])
        #expect(flags.management.tmpFs == ["/run:64m"])
        #expect(flags.management.networks == ["default"])
        #expect(flags.management.labels == ["app=web"])
        #expect(flags.management.capAdd == ["NET_ADMIN"])
        #expect(flags.management.capDrop == ["CHOWN"])
        #expect(flags.management.shmSize == "64m")
        #expect(flags.management.readOnly)
        #expect(flags.management.remove)
        #expect(flags.management.rosetta)
        #expect(flags.management.dns.nameservers == ["1.1.1.1"])
        #expect(flags.management.dns.domain == "test")
        #expect(flags.management.dns.searchDomains == ["svc.local"])

        #expect(flags.resource.cpus == 2)
        #expect(flags.resource.memory == "512m")
    }

    /// An environment value containing `=` must survive, as it must everywhere
    /// else in the app.
    @Test func environmentValuesKeepTheirEqualsSigns() throws {
        let flags = try spec().toFlags()
        #expect(flags.process.env.contains("QUERY=a=1&b=2"))
    }

    /// Blank optional fields must stay absent rather than becoming empty
    /// strings, or the runtime would treat "" as a deliberate choice.
    @Test func blanksBecomeNilNotEmptyStrings() throws {
        let flags = try RunSpec(image: "alpine").toFlags()

        #expect(flags.management.name == nil)
        #expect(flags.management.entrypoint == nil)
        #expect(flags.management.shmSize == nil)
        #expect(flags.management.kernel == nil)
        #expect(flags.management.platform == nil)
        #expect(flags.process.user == nil)
        #expect(flags.process.cwd == nil)
        #expect(flags.resource.cpus == nil)
        #expect(flags.resource.memory == nil)
    }

    /// The list editors leave blank rows behind; they must not be sent.
    @Test func blankListEntriesAreDropped() throws {
        var spec = RunSpec(image: "alpine")
        spec.publishedPorts = ["8080:80", "", "   "]
        spec.networks = ["", "default"]
        spec.environment = [.init(key: "A", value: "1"), .init(key: "", value: "ignored")]

        let flags = try spec.toFlags()

        #expect(flags.management.publishPorts == ["8080:80"])
        #expect(flags.management.networks == ["default"])
        #expect(flags.process.env == ["A=1"])
    }

    /// Untouched flags keep upstream's defaults, which is how the app inherits
    /// the CLI's behaviour for anything the sheet does not set.
    @Test func untouchedFlagsKeepUpstreamDefaults() throws {
        let flags = try RunSpec(image: "alpine").toFlags()

        #expect(flags.management.os == "linux")
        #expect(!flags.management.arch.isEmpty)
        // 1.4.1 defaults this to `https`, where 1.0.0 used `auto`.
        #expect(flags.registry.scheme == "https")
        #expect(flags.imageFetch.maxConcurrentDownloads == 3)
    }

    /// An image on this machine is served over plain HTTP, and 1.4.1 removed
    /// the `auto` scheme that used to work that out.
    @Test func anImageFromALocalRegistryIsFetchedOverHTTP() throws {
        let flags = try RunSpec(image: "127.0.0.1:15000/app:1").toFlags()
        #expect(flags.registry.scheme == "http")

        let localhost = try RunSpec(image: "localhost:5000/app:1").toFlags()
        #expect(localhost.registry.scheme == "http")
    }

    @Test func aRemoteImageKeepsHTTPS() throws {
        #expect(try RunSpec(image: "ghcr.io/me/app:1").toFlags().registry.scheme == "https")
        #expect(try RunSpec(image: "alpine:3.20").toFlags().registry.scheme == "https")
    }
}

@MainActor
@Suite struct RunStoreTests {

    @Test func successfulCreateReportsTheID() async {
        let backend = MockBackend(images: [.stub()])
        let store = RunStore(backend: backend)

        let id = await store.create(spec: RunSpec(image: "alpine:3.20"), then: false)

        #expect(id == "created-1")
        #expect(store.state == .created(id: "created-1"))
        #expect(backend.calls.createContainer == 1)
        #expect(backend.calls.start == 0)
    }

    @Test func createAndStartStartsIt() async {
        let backend = MockBackend(images: [.stub()])
        let store = RunStore(backend: backend)

        _ = await store.create(spec: RunSpec(image: "alpine:3.20"), then: true)

        #expect(backend.calls.start == 1)
    }

    @Test func failureIsReported() async {
        let backend = MockBackend()
        backend.setFailure(.upstream(code: "invalidArgument", message: "no such image"))
        let store = RunStore(backend: backend)

        let id = await store.create(spec: RunSpec(image: "nope"), then: false)

        #expect(id == nil)
        #expect(store.state == .failed(.upstream(code: "invalidArgument", message: "no such image")))
    }

    @Test func progressIsReportedWhileWorking() async {
        let backend = MockBackend(images: [.stub()])
        var progress = PullProgress()
        progress.apply([.description("Fetching image"), .setTotalSize(100), .setSize(40)])
        backend.setCreateProgress([progress])
        let store = RunStore(backend: backend)

        _ = await store.create(spec: RunSpec(image: "alpine:3.20"), then: false)

        #expect(backend.calls.createContainer == 1)
        #expect(store.state == .created(id: "created-1"))
    }

    @Test func resetReturnsToIdle() async {
        let backend = MockBackend(images: [.stub()])
        let store = RunStore(backend: backend)
        _ = await store.create(spec: RunSpec(image: "alpine:3.20"), then: false)

        store.reset()

        #expect(store.state == .idle)
    }
}
