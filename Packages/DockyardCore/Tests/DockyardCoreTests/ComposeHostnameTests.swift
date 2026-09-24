import Foundation
import Testing

@testable import DockyardCore

/// The riskiest code in the compose feature. These are mostly adversarial: the
/// failure that matters is not "a hostname was missed", it is "a value that was
/// never a hostname got corrupted".
@Suite struct ComposeHostnameTests {

    private let services: Set<String> = ["db", "cache", "api", "rabbit", "k1", "k2"]

    private func resolved(_ service: String) -> String { "shop-\(service).test" }

    private func rewrite(_ key: String, _ value: String) -> ComposeHostnames.Result {
        ComposeHostnames.rewrite(
            environment: [.init(key: key, value: value)],
            serviceNames: services,
            service: "web",
            resolvedName: resolved
        )
    }

    private func value(_ key: String, _ value: String) -> String {
        rewrite(key, value).environment[0].value
    }

    // MARK: - Tier A: URLs

    @Test func rewritesTheHostOfAConnectionURL() {
        #expect(
            value("DATABASE_URL", "postgres://db:5432/app")
                == "postgres://shop-db.test:5432/app"
        )
    }

    /// Credentials, port, path and query must come through byte-identical — the
    /// reason only the host capture is replaced rather than the string rebuilt.
    @Test func credentialsAndQueryAreUntouched() {
        #expect(
            value("DATABASE_URL", "postgres://user:p@ss=w0rd@db:5432/app?sslmode=require")
                == "postgres://user:p@ss=w0rd@shop-db.test:5432/app?sslmode=require"
        )
    }

    /// `URLComponents(string:)?.host` is nil for this, which is why the
    /// implementation uses a regex instead.
    @Test func handlesSchemesURLComponentsCannotParse() {
        #expect(URLComponents(string: "jdbc:postgresql://db:5432/app")?.host == nil)
        #expect(
            value("JDBC_URL", "jdbc:postgresql://db:5432/app")
                == "jdbc:postgresql://shop-db.test:5432/app"
        )
        #expect(
            value("AMQP_URL", "amqp://guest:guest@rabbit//")
                == "amqp://guest:guest@shop-rabbit.test//"
        )
    }

    /// A URL is rewritten whatever its key is called — the scheme is signal
    /// enough on its own.
    @Test func aURLIsRewrittenRegardlessOfItsKey() {
        #expect(value("ANYTHING_AT_ALL", "redis://cache:6379/0") == "redis://shop-cache.test:6379/0")
    }

    @Test func aHostThatIsNotAServiceIsLeftAlone() {
        #expect(value("DATABASE_URL", "postgres://example.com:5432/app") == "postgres://example.com:5432/app")
        #expect(value("API_URL", "https://api.github.com/x") == "https://api.github.com/x")
    }

    @Test func severalURLsInOneValueAreAllRewritten() {
        #expect(
            value("URLS", "redis://cache:6379,postgres://db:5432/app")
                == "redis://shop-cache.test:6379,postgres://shop-db.test:5432/app"
        )
    }

    // MARK: - Tier B: bare hosts

    @Test func rewritesABareHostUnderAHostShapedKey() {
        #expect(value("DB_HOST", "db") == "shop-db.test")
        #expect(value("PGHOST", "db") == "shop-db.test")
        #expect(value("REDIS_ADDR", "cache:6379") == "shop-cache.test:6379")
        #expect(value("API_ENDPOINT", "api:3000") == "shop-api.test:3000")
    }

    /// Every piece, with the separators preserved exactly.
    @Test func rewritesEveryPieceOfABrokerList() {
        #expect(value("KAFKA_BROKERS", "k1:9092,k2:9092") == "shop-k1.test:9092,shop-k2.test:9092")
        #expect(value("KAFKA_BROKERS", "k1:9092, k2:9092") == "shop-k1.test:9092, shop-k2.test:9092")
    }

    /// The case the whole key rule exists for. `db` is a service name and this
    /// value is exactly `db`, but the key says it is a username.
    @Test func aUsernameThatHappensToMatchAServiceIsNotRewritten() {
        #expect(value("POSTGRES_USER", "db") == "db")
        #expect(value("DB_USER", "db") == "db")
        #expect(value("POSTGRES_DB", "db") == "db")
        #expect(value("APP_NAME", "api") == "api")
        #expect(value("SECRET_KEY", "cache") == "cache")
    }

    /// The last segment decides, so a `DB_` prefix does not disqualify a key
    /// whose final word says "host". Getting this wrong rejects the commonest
    /// hostname keys there are.
    @Test(arguments: [
        ("DB_HOST", true), ("DATABASE_URL", true), ("POSTGRES_HOST", true),
        ("DB_HOSTNAME", true), ("REDIS_ADDR", true), ("KAFKA_BROKERS", true), ("PGHOST", true),
        ("DB_USER", false), ("POSTGRES_DB", false), ("APP_NAME", false),
        ("SECRET_KEY", false), ("HOST_USER", false), ("BACKEND", false),
    ])
    func theLastSegmentOfAKeyDecides(_ key: String, _ isHost: Bool) {
        #expect(ComposeHostnames.keyLooksLikeAHost(key) == isHost, "\(key)")
    }

    @Test func aPartialMatchInsideALongerValueIsNotTouched() {
        // Only a whole piece counts, so free text is never rewritten.
        #expect(value("APP_HOST", "the db is over there") == "the db is over there")
        #expect(value("DB_HOST", "dbx") == "dbx")
        #expect(value("DB_HOST", "mydb") == "mydb")
        #expect(value("DB_HOST", "db.example.com") == "db.example.com")
    }

    @Test func aNonNumericPortIsNotTreatedAsAHostPort() {
        #expect(value("DB_HOST", "db:notaport") == "db:notaport")
    }

    // MARK: - Candidates

    /// A genuine hostname under an unhelpful key. Not rewritten — reported, so
    /// the user can see it rather than wonder why the stack cannot connect.
    @Test func aHostnameUnderAnUnhelpfulKeyIsReportedNotRewritten() {
        let result = rewrite("BACKEND", "api")
        #expect(result.environment[0].value == "api")
        #expect(result.rewrites.isEmpty)
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].matchedService == "api")
        #expect(result.candidates[0].display.contains("api"))
    }

    /// A value that was rewritten is not also a candidate.
    @Test func aRewrittenValueIsNotAlsoReportedAsACandidate() {
        let result = rewrite("DB_HOST", "db")
        #expect(result.rewrites.count == 1)
        #expect(result.candidates.isEmpty)
    }

    @Test func aValueNamingNoServiceIsNeitherRewrittenNorReported() {
        let result = rewrite("SOME_KEY", "hello")
        #expect(result.rewrites.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    // MARK: - Properties

    /// Running `up` twice must not mangle what the first run produced. The
    /// rewritten name is not itself a service name, so the second pass is a
    /// no-op — but that is worth asserting rather than assuming.
    @Test func rewritingIsIdempotent() {
        for (key, original) in [
            ("DATABASE_URL", "postgres://user:pass@db:5432/app"),
            ("DB_HOST", "db"),
            ("KAFKA_BROKERS", "k1:9092,k2:9092"),
            ("AMQP_URL", "amqp://guest:guest@rabbit//"),
        ] {
            let once = value(key, original)
            let twice = value(key, once)
            #expect(once == twice, "\(key) changed on a second pass: \(once) → \(twice)")
        }
    }

    @Test func everyChangeIsRecordedWithBothSides() {
        let result = ComposeHostnames.rewrite(
            environment: [
                .init(key: "DATABASE_URL", value: "postgres://db:5432/app"),
                .init(key: "REDIS_HOST", value: "cache"),
                .init(key: "POSTGRES_USER", value: "db"),
            ],
            serviceNames: services,
            service: "web",
            resolvedName: resolved
        )

        #expect(result.rewrites.count == 2)
        let urlRewrite = try? #require(result.rewrites.first { $0.key == "DATABASE_URL" })
        #expect(urlRewrite?.before == "postgres://db:5432/app")
        #expect(urlRewrite?.after == "postgres://shop-db.test:5432/app")
        #expect(urlRewrite?.rule == .urlAuthority)
        #expect(result.rewrites.first { $0.key == "REDIS_HOST" }?.rule == .hostPort)
        #expect(result.rewrites.allSatisfy { $0.service == "web" })
        #expect(result.rewrites.first?.display.contains("→") == true)
    }

    @Test func anEmptyEnvironmentIsHandled() {
        let result = ComposeHostnames.rewrite(
            environment: [],
            serviceNames: services,
            service: "web",
            resolvedName: resolved
        )
        #expect(result.environment.isEmpty)
        #expect(result.rewrites.isEmpty)
    }

    /// Order and keys must survive untouched; only values may change.
    @Test func keysAndOrderAreUnchanged() {
        let input: [RunSpec.KeyValue] = [
            .init(key: "Z_LAST", value: "x"),
            .init(key: "DB_HOST", value: "db"),
            .init(key: "A_FIRST", value: "y"),
        ]
        let result = ComposeHostnames.rewrite(
            environment: input, serviceNames: services, service: "web", resolvedName: resolved
        )
        #expect(result.environment.map(\.key) == ["Z_LAST", "DB_HOST", "A_FIRST"])
        #expect(result.environment.map(\.value) == ["x", "shop-db.test", "y"])
    }
}

/// Rewriting applied to the realistic stack from T22, so the two pieces are
/// exercised together rather than only in isolation.
@Suite struct ComposeHostnameEndToEndTests {

    @Test func aRealisticStackGetsExactlyTheRewritesItNeeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-rewrite-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("compose.yaml")
        try """
            name: shop
            services:
              db:
                image: postgres:16
                environment:
                  POSTGRES_USER: db
                  POSTGRES_DB: db
              cache:
                image: redis:7-alpine
              web:
                image: nginx:alpine
                environment:
                  DATABASE_URL: postgres://db:secret@db:5432/shop
                  REDIS_HOST: cache
                  CACHE_ADDR: cache:6379
                  BACKEND: cache
                  APP_NAME: web
                  GREETING: the db is over there
            """.write(to: file, atomically: true, encoding: .utf8)

        let project = try #require(ComposeLoader(processEnvironment: [:]).load(fileURL: file).spec)
        let web = try #require(project.service(named: "web"))

        let result = ComposeHostnames.rewrite(
            environment: web.environment,
            serviceNames: project.serviceNames,
            service: "web",
            resolvedName: { "shop-\($0).test" }
        )

        func value(_ key: String) -> String? { result.environment.first { $0.key == key }?.value }

        // The host is rewritten; the username `db` in the credentials is not.
        #expect(value("DATABASE_URL") == "postgres://db:secret@shop-db.test:5432/shop")
        #expect(value("REDIS_HOST") == "shop-cache.test")
        #expect(value("CACHE_ADDR") == "shop-cache.test:6379")

        // Left exactly as written.
        #expect(value("APP_NAME") == "web")
        #expect(value("GREETING") == "the db is over there")

        // A real hostname under a key that gives no signal: reported, not changed.
        #expect(value("BACKEND") == "cache")
        #expect(result.candidates.map(\.key) == ["BACKEND"])

        #expect(result.rewrites.map(\.key).sorted() == ["CACHE_ADDR", "DATABASE_URL", "REDIS_HOST"])

        // The db service's own environment names services but is all credentials.
        let dbService = try #require(project.service(named: "db"))
        let dbResult = ComposeHostnames.rewrite(
            environment: dbService.environment,
            serviceNames: project.serviceNames,
            service: "db",
            resolvedName: { "shop-\($0).test" }
        )
        #expect(dbResult.rewrites.isEmpty, "credentials must never be rewritten")
        #expect(dbResult.environment.allSatisfy { $0.value == "db" })
    }
}

/// Which keys end up in the Rewrites pane's "not rewritten" list. The pane is
/// only useful if it holds the cases a user has to act on and nothing else.
@Suite struct ComposeHostnameCandidateTests {

    private let services: Set<String> = ["db", "cache", "web"]

    private func candidates(_ pairs: [(String, String)], service: String = "web") -> [String] {
        ComposeHostnames.rewrite(
            environment: pairs.map { .init(key: $0.0, value: $0.1) },
            serviceNames: services,
            service: service,
            resolvedName: { "shop-\($0).test" }
        ).candidates.map(\.key)
    }

    /// A key we are confident about is not a candidate — reporting
    /// `POSTGRES_USER=db` would bury the one entry that matters.
    @Test func denyListedKeysAreNotReported() {
        #expect(candidates([("POSTGRES_USER", "db"), ("POSTGRES_DB", "db"), ("APP_NAME", "cache")]).isEmpty)
    }

    @Test func aServiceNamingItselfIsNotReported() {
        #expect(candidates([("SOMETHING", "web")], service: "web").isEmpty)
    }

    @Test func anAmbiguousKeyNamingAnotherServiceIsReported() {
        #expect(candidates([("BACKEND", "db")]) == ["BACKEND"])
        #expect(candidates([("QUEUE", "cache")]) == ["QUEUE"])
    }

    @Test(arguments: [
        ("DB_HOST", ComposeHostnames.KeyConfidence.host),
        ("POSTGRES_USER", .notHost),
        ("BACKEND", .ambiguous),
    ])
    func confidenceIsThreeWayNotTwo(_ key: String, _ expected: ComposeHostnames.KeyConfidence) {
        #expect(ComposeHostnames.confidence(for: key) == expected)
    }
}

extension ComposeHostnames.KeyConfidence: @retroactive Equatable {}
