import Foundation
import Testing

@testable import DockyardCore

@Suite struct ComposeParserTests {

    private func parse(_ yaml: String, environment: [String: String] = [:])
        -> (spec: ComposeProjectSpec?, diagnostics: [ComposeDiagnostic])
    {
        ComposeParser.parse(
            yaml: yaml,
            projectName: "proj",
            fileURL: URL(fileURLWithPath: "/tmp/proj/compose.yaml"),
            environment: environment
        )
    }

    @Test func readsAMinimalFile() throws {
        let (spec, diagnostics) = parse("""
            services:
              web:
                image: nginx:alpine
            """)
        let project = try #require(spec)
        #expect(!diagnostics.blocks)
        #expect(project.services.map(\.name) == ["web"])
        #expect(project.services[0].image == "nginx:alpine")
        #expect(project.name == "proj")
    }

    @Test func aTopLevelNameWins() throws {
        let (spec, _) = parse("name: shop\nservices:\n  web:\n    image: nginx\n")
        #expect(try #require(spec).name == "shop")
    }

    /// Both spellings are equally common, and handling one rejects half of real
    /// files.
    @Test func environmentParsesAsAMapAndAsAList() throws {
        let asMap = try #require(parse("""
            services:
              web:
                image: nginx
                environment:
                  A: "1"
                  B: two
            """).spec)
        let asList = try #require(parse("""
            services:
              web:
                image: nginx
                environment:
                  - A=1
                  - B=two
            """).spec)
        #expect(asMap.services[0].environment.map(\.joined) == ["A=1", "B=two"])
        #expect(asList.services[0].environment.map(\.joined) == ["A=1", "B=two"])
    }

    /// A bare `KEY` in list form means "take it from the environment".
    @Test func aValuelessEntryBecomesAnEmptyValue() throws {
        let spec = try #require(parse("""
            services:
              web:
                image: nginx
                environment: ["DEBUG"]
            """).spec)
        #expect(spec.services[0].environment.map(\.joined) == ["DEBUG="])
    }

    @Test func dependsOnParsesAsAListAndAsAMap() throws {
        let asList = try #require(parse("""
            services:
              web:
                image: nginx
                depends_on: [db, cache]
              db: { image: postgres }
              cache: { image: redis }
            """).spec)
        #expect(asList.service(named: "web")?.dependsOn == ["cache", "db"])

        let (spec, diagnostics) = parse("""
            services:
              web:
                image: nginx
                depends_on:
                  db:
                    condition: service_healthy
              db: { image: postgres }
            """)
        #expect(try #require(spec).service(named: "web")?.dependsOn == ["db"])
        // We can watch a container start; we cannot watch it become ready.
        #expect(diagnostics.contains { $0.path.hasSuffix("condition") && $0.severity == .ignored })
    }

    @Test func portsAndVolumesParse() throws {
        let spec = try #require(parse("""
            services:
              web:
                image: nginx
                ports: ["8080:80", "127.0.0.1:9000:9000", "53:53/udp", "3000"]
                volumes:
                  - ./src:/app
                  - data:/var/lib/data
                  - /etc/localtime:/etc/localtime:ro
                  - /scratch
            """).spec)
        let web = try #require(spec.service(named: "web"))
        #expect(web.ports.map(\.published) == ["8080:80", "127.0.0.1:9000:9000", "53:53/udp", "3000:3000"])
        #expect(web.volumes.map(\.kind) == [.bind, .named, .bind, .anonymous])
        #expect(web.volumes[1].source == "data")
        #expect(web.volumes[2].readOnly)
        #expect(!web.volumes[0].readOnly)
    }

    @Test func aPortRangeIsRefusedRatherThanMisread() throws {
        let (_, diagnostics) = parse("""
            services:
              web:
                image: nginx
                ports: ["8000-8010:8000"]
            """)
        #expect(diagnostics.contains { $0.path.hasSuffix("ports") && $0.severity == .warning })
    }

    /// The compose spec keeps growing. Refusing a file over one unrecognised
    /// key would make the app useless on files that otherwise run perfectly.
    @Test func anUnknownKeyIsAWarningAndTheFileStillLoads() throws {
        let (spec, diagnostics) = parse("""
            services:
              web:
                image: nginx
                some_future_key: yes
            """)
        #expect(spec != nil)
        #expect(!diagnostics.blocks)
        #expect(diagnostics.contains { $0.path == "services.web.some_future_key" && $0.severity == .warning })
    }

    @Test func anXPrefixedKeyIsNotEvenWarnedAbout() throws {
        let (_, diagnostics) = parse("""
            services:
              web:
                image: nginx
                x-anything: here
            """)
        #expect(!diagnostics.contains { $0.path.contains("x-anything") })
    }

    @Test(arguments: [
        ("healthcheck", "healthcheck:\n      test: [\"CMD\", \"true\"]"),
        ("networks", "networks: [backend]"),
        ("container_name", "container_name: fixed"),
        ("profiles", "profiles: [dev]"),
        ("deploy", "deploy:\n      replicas: 2"),
    ])
    func unsupportedKeysAreNamedNotDropped(_ key: String, _ snippet: String) throws {
        let (spec, diagnostics) = parse("""
            services:
              web:
                image: nginx
                \(snippet)
            """)
        #expect(spec != nil, "an unsupported key must not stop the file loading")
        #expect(
            diagnostics.contains { $0.path == "services.web.\(key)" && $0.severity == .ignored },
            "\(key) must be reported by name"
        )
    }

    @Test func aServiceWithNoImageIsRefused() {
        let (spec, diagnostics) = parse("services:\n  web:\n    command: sleep 1\n")
        #expect(spec == nil)
        #expect(diagnostics.blocks)
    }

    /// Building is Phase 2; until then the message has to say so rather than
    /// complaining about a missing image.
    @Test func aBuiltServiceSaysSoRatherThanBlamingTheImage() {
        let (_, diagnostics) = parse("services:\n  web:\n    build: .\n")
        #expect(diagnostics.errors.contains { $0.message.contains("built") })
    }

    @Test func malformedYAMLFailsWithALine() {
        let (spec, diagnostics) = parse("services:\n  web:\n   image: \"unterminated\n  bad indent\n")
        #expect(spec == nil)
        #expect(diagnostics.blocks)
    }

    @Test func interpolationRunsBeforeAnythingIsInterpreted() throws {
        let spec = try #require(parse(
            """
            services:
              web:
                image: nginx:${TAG:-latest}
                ports: ["${PORT}:80"]
            """,
            environment: ["PORT": "8080"]
        ).spec)
        #expect(spec.services[0].image == "nginx:latest")
        #expect(spec.services[0].ports.map(\.published) == ["8080:80"])
    }

    @Test func aMissingRequiredVariableBlocksTheFile() {
        let (spec, diagnostics) = parse("""
            services:
              web:
                image: nginx:${TAG:?pick a tag}
            """)
        #expect(spec == nil)
        #expect(diagnostics.errors.contains { $0.message.contains("TAG") && $0.message.contains("pick a tag") })
    }

    @Test func restartPoliciesRoundTripThroughTheirLabel() throws {
        for (written, expected) in [
            ("always", ComposeRestartPolicy.always),
            ("unless-stopped", .unlessStopped),
            ("on-failure", .onFailure(maxRetries: nil)),
            ("on-failure:3", .onFailure(maxRetries: 3)),
            ("no", .no),
        ] {
            let spec = try #require(parse("services:\n  web:\n    image: nginx\n    restart: \(written)\n").spec)
            #expect(spec.services[0].restart == expected)
            #expect(ComposeRestartPolicy(labelValue: expected.labelValue) == expected)
        }
    }

    /// The supervisor only runs while the app is open, so a file asking for
    /// restarts has to be told that up front.
    @Test func anAutomaticRestartPolicyIsReportedAsSupervised() {
        let (_, diagnostics) = parse("services:\n  web:\n    image: nginx\n    restart: always\n")
        #expect(diagnostics.contains { $0.path.hasSuffix("restart") && $0.message.contains("while it is open") })
    }

    @Test func servicesComeBackSortedSoTwoLoadsAreIdentical() throws {
        let spec = try #require(parse("""
            services:
              zebra: { image: a }
              alpha: { image: b }
              middle: { image: c }
            """).spec)
        #expect(spec.services.map(\.name) == ["alpha", "middle", "zebra"])
    }

    @Test func declaredVolumesRecordWhetherTheyAreExternal() throws {
        let spec = try #require(parse("""
            services:
              web: { image: nginx }
            volumes:
              data:
              shared:
                external: true
            """).spec)
        #expect(spec.declaredVolumes.map(\.name) == ["data", "shared"])
        #expect(spec.declaredVolumes.first { $0.name == "shared" }?.isExternal == true)
    }

    @Test func aServiceCanOptOutOfHostnameRewriting() throws {
        let spec = try #require(parse("""
            services:
              web:
                image: nginx
                x-dockyard:
                  rewrite: false
            """).spec)
        #expect(spec.services[0].rewriteHostnames == false)
    }
}
