import Foundation
import Testing

@testable import DockyardCore

/// The loader is the only compose type that touches the filesystem, so these
/// use real temporary files — path resolution is the thing most likely to be
/// wrong, and a stubbed filesystem would not catch it.
@Suite struct ComposeLoaderTests {

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-compose-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func loadsAFileFromDisk() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("compose.yaml")
            try write("services:\n  web:\n    image: nginx\n", to: file)

            let (spec, diagnostics) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)

            #expect(!diagnostics.blocks)
            #expect(try #require(spec).services.map(\.name) == ["web"])
        }
    }

    @Test func findsTheConventionalFileInAFolder() throws {
        try withDirectory { directory in
            try write("services:\n  web:\n    image: nginx\n", to: directory.appendingPathComponent("docker-compose.yml"))
            let found = ComposeLoader().discover(in: directory)
            #expect(found?.lastPathComponent == "docker-compose.yml")
        }
    }

    @Test func aDotEnvBesideTheFileIsUsedForInterpolation() throws {
        try withDirectory { directory in
            try write("TAG=1.27\n", to: directory.appendingPathComponent(".env"))
            let file = directory.appendingPathComponent("compose.yaml")
            try write("services:\n  web:\n    image: nginx:${TAG}\n", to: file)

            let (spec, _) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
            #expect(try #require(spec).services[0].image == "nginx:1.27")
        }
    }

    @Test func theProcessEnvironmentBeatsDotEnv() throws {
        try withDirectory { directory in
            try write("TAG=from-file\n", to: directory.appendingPathComponent(".env"))
            let file = directory.appendingPathComponent("compose.yaml")
            try write("services:\n  web:\n    image: nginx:${TAG}\n", to: file)

            let (spec, _) = ComposeLoader(processEnvironment: ["TAG": "from-process"]).load(fileURL: file)
            #expect(try #require(spec).services[0].image == "nginx:from-process")
        }
    }

    /// The reason `env_file` is read here rather than handed to the runtime:
    /// upstream resolves it against Dockyard's working directory, not the
    /// compose file's, so a relative path would silently miss.
    @Test func envFileIsResolvedAgainstTheComposeFileNotTheProcess() throws {
        try withDirectory { directory in
            try write("DB_HOST=db\nSHARED=from-file\n", to: directory.appendingPathComponent("service.env"))
            let file = directory.appendingPathComponent("compose.yaml")
            try write("""
                services:
                  web:
                    image: nginx
                    env_file: service.env
                """, to: file)

            let (spec, diagnostics) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
            #expect(!diagnostics.blocks)
            let environment = try #require(spec).services[0].environment
            #expect(environment.contains { $0.key == "DB_HOST" && $0.value == "db" })
            // Never passed through to the runtime, which would resolve it wrongly.
            #expect(try #require(spec).services[0].envFiles == ["service.env"])
        }
    }

    @Test func environmentBeatsEnvFile() throws {
        try withDirectory { directory in
            try write("SHARED=from-file\n", to: directory.appendingPathComponent("service.env"))
            let file = directory.appendingPathComponent("compose.yaml")
            try write("""
                services:
                  web:
                    image: nginx
                    env_file: service.env
                    environment:
                      SHARED: from-compose
                """, to: file)

            let (spec, _) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
            let environment = try #require(spec).services[0].environment
            #expect(environment.first { $0.key == "SHARED" }?.value == "from-compose")
        }
    }

    @Test func aMissingEnvFileIsAnErrorNamingIt() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("compose.yaml")
            try write("services:\n  web:\n    image: nginx\n    env_file: nope.env\n", to: file)

            let (spec, diagnostics) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
            #expect(spec == nil)
            #expect(diagnostics.errors.contains { $0.message.contains("nope.env") })
        }
    }

    @Test func anUnreadableFileFailsWithoutCrashing() {
        let (spec, diagnostics) = ComposeLoader().load(
            fileURL: URL(fileURLWithPath: "/nonexistent/compose.yaml")
        )
        #expect(spec == nil)
        #expect(diagnostics.blocks)
    }

    @Test(arguments: [
        ("My Project", "my-project"),
        ("shop_v2", "shop-v2"),
        ("  spaced  ", "spaced"),
        ("UPPER", "upper"),
        ("a...b", "a-b"),
        ("--leading", "leading"),
    ])
    func folderNamesAreSanitisedIntoUsableProjectNames(_ raw: String, _ expected: String) {
        #expect(ComposeLoader.sanitise(raw) == expected)
    }

    @Test func theProjectNameDefaultsToTheFolder() throws {
        try withDirectory { directory in
            let named = directory.appendingPathComponent("My Shop")
            try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
            let file = named.appendingPathComponent("compose.yaml")
            try write("services:\n  web:\n    image: nginx\n", to: file)

            let (spec, _) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
            #expect(try #require(spec).name == "my-shop")
        }
    }
}

/// A file of the shape people actually have, rather than a snippet built to
/// exercise one branch.
@Suite struct ComposeRealisticFileTests {

    @Test func aTypicalWebStackParsesWithNoBlockingProblems() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-realistic-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "POSTGRES_PASSWORD=secret\nTAG=16\n"
            .write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let file = directory.appendingPathComponent("compose.yaml")
        try """
            name: shop

            services:
              db:
                image: postgres:${TAG}
                restart: unless-stopped
                environment:
                  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set it in .env}
                  POSTGRES_DB: shop
                volumes:
                  - pgdata:/var/lib/postgresql/data
                healthcheck:
                  test: ["CMD-SHELL", "pg_isready -U postgres"]
                  interval: 5s

              cache:
                image: redis:7-alpine
                command: redis-server --save ""

              web:
                image: nginx:alpine
                depends_on:
                  db:
                    condition: service_healthy
                  cache:
                    condition: service_started
                ports:
                  - "8080:80"
                environment:
                  DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@db:5432/shop
                  REDIS_HOST: cache
                volumes:
                  - ./site:/usr/share/nginx/html:ro

            volumes:
              pgdata:
            """.write(to: file, atomically: true, encoding: .utf8)

        let (spec, diagnostics) = ComposeLoader(processEnvironment: [:]).load(fileURL: file)
        let project = try #require(spec, "diagnostics: \(diagnostics.map(\.display))")

        #expect(project.name == "shop")
        #expect(project.services.map(\.name) == ["cache", "db", "web"])
        #expect(project.declaredVolumes.map(\.name) == ["pgdata"])

        // Interpolation, including a value drawn from .env through a second
        // variable inside a URL.
        #expect(project.service(named: "db")?.image == "postgres:16")
        let web = try #require(project.service(named: "web"))
        #expect(
            web.environment.first { $0.key == "DATABASE_URL" }?.value
                == "postgres://postgres:secret@db:5432/shop"
        )
        #expect(web.ports.map(\.published) == ["8080:80"])
        #expect(web.volumes.first?.readOnly == true)
        #expect(web.dependsOn == ["cache", "db"])

        // The order the stack has to come up in.
        #expect(try ComposeGraph.startOrder(project.services).get() == ["cache", "db", "web"])

        // Nothing blocks, and the two things this runtime cannot do are named
        // rather than silently dropped.
        #expect(!diagnostics.blocks)
        #expect(diagnostics.contains { $0.path == "services.db.healthcheck" })
        #expect(diagnostics.contains { $0.path.contains("depends_on.db.condition") })
    }
}
