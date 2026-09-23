import Foundation
import Testing

@testable import DockyardCore

/// Variable substitution. Not a nicety — nearly every real compose file has at
/// least a `${TAG:-latest}`, and a parser that cannot do this rejects files
/// that work everywhere else.
@Suite struct ComposeInterpolationTests {

    private func expand(_ text: String, _ values: [String: String] = [:]) -> String {
        var failures: [ComposeInterpolation.Failure] = []
        return ComposeInterpolation.expand(text, values: values, failures: &failures)
    }

    private func failures(_ text: String, _ values: [String: String] = [:]) -> [ComposeInterpolation.Failure] {
        var failures: [ComposeInterpolation.Failure] = []
        _ = ComposeInterpolation.expand(text, values: values, failures: &failures)
        return failures
    }

    @Test func substitutesBothSpellings() {
        #expect(expand("$TAG", ["TAG": "1.2"]) == "1.2")
        #expect(expand("${TAG}", ["TAG": "1.2"]) == "1.2")
        #expect(expand("nginx:${TAG}-alpine", ["TAG": "1.27"]) == "nginx:1.27-alpine")
    }

    @Test func anUnsetVariableBecomesEmpty() {
        #expect(expand("a${NOPE}b") == "ab")
    }

    /// `:-` treats empty as unset, `-` does not. The distinction is the whole
    /// reason both spellings exist.
    @Test func defaultsDistinguishUnsetFromEmpty() {
        #expect(expand("${TAG:-latest}", [:]) == "latest")
        #expect(expand("${TAG:-latest}", ["TAG": ""]) == "latest")
        #expect(expand("${TAG-latest}", [:]) == "latest")
        #expect(expand("${TAG-latest}", ["TAG": ""]) == "")
        #expect(expand("${TAG:-latest}", ["TAG": "1.0"]) == "1.0")
    }

    @Test func requiredVariablesFailByName() {
        let reported = failures("${DB_PASSWORD:?set this in .env}")
        #expect(reported.count == 1)
        #expect(reported.first?.variable == "DB_PASSWORD")
        #expect(reported.first?.message == "set this in .env")
    }

    @Test func aRequiredVariableWithNoMessageStillSaysWhichOne() {
        let reported = failures("${API_KEY:?}")
        #expect(reported.first?.variable == "API_KEY")
        #expect(reported.first?.message.contains("required") == true)
    }

    @Test func aSetRequiredVariableIsNotAFailure() {
        #expect(failures("${API_KEY:?missing}", ["API_KEY": "abc"]).isEmpty)
        #expect(expand("${API_KEY:?missing}", ["API_KEY": "abc"]) == "abc")
    }

    /// Every missing variable is collected, so a file short of three says so
    /// once rather than over three separate attempts.
    @Test func everyRequiredVariableIsReportedTogether() {
        let reported = failures("${A:?a} ${B:?b} ${C:?c}")
        #expect(reported.map(\.variable) == ["A", "B", "C"])
    }

    @Test func doubleDollarIsALiteralDollar() {
        #expect(expand("$$HOME") == "$HOME")
        #expect(expand("cost is $$5") == "cost is $5")
    }

    /// `$` before punctuation or at the end of a string is literal.
    @Test func aDollarBeforePunctuationIsLeftAlone() {
        #expect(expand("$2y$10") == "$2y$10")
        #expect(expand("100$") == "100$")
    }

    /// `$` before a letter is a variable reference, even in the middle of what
    /// looks like a password hash — so `$2y$10$abcdef` loses its tail. This is
    /// compose's own behaviour, not ours, and is exactly why Docker tells you to
    /// write `$$` in a compose file. Pinned here so nobody later "fixes" it into
    /// a divergence from every other compose tool.
    @Test func aDollarBeforeALetterIsAVariableEvenInsideAHash() {
        #expect(expand("$2y$10$abcdef") == "$2y$10")
        #expect(expand("$$2y$$10$$abcdef") == "$2y$10$abcdef")
    }

    @Test func theProcessEnvironmentBeatsDotEnv() {
        let values = ComposeInterpolation.values(
            processEnvironment: ["TAG": "from-process"],
            dotEnv: ["TAG": "from-file", "ONLY_IN_FILE": "yes"]
        )
        #expect(values["TAG"] == "from-process")
        #expect(values["ONLY_IN_FILE"] == "yes")
    }

    @Test func anUnterminatedBraceIsLeftAsWritten() {
        #expect(expand("${UNCLOSED") == "${UNCLOSED")
    }
}

/// `.env` parsing.
@Suite struct ComposeEnvFileTests {

    @Test func readsPlainAssignments() {
        let values = ComposeLoader.parseEnv("A=1\nB=two\n")
        #expect(values == ["A": "1", "B": "two"])
    }

    @Test func skipsCommentsAndBlankLines() {
        let values = ComposeLoader.parseEnv("# a comment\n\nA=1\n   # indented\n")
        #expect(values == ["A": "1"])
    }

    @Test func toleratesExportAndQuotes() {
        let values = ComposeLoader.parseEnv("export A=\"quoted\"\nB='single'\n")
        #expect(values == ["A": "quoted", "B": "single"])
    }

    /// A password containing `=` must survive intact.
    @Test func keepsEverythingAfterTheFirstEquals() {
        let values = ComposeLoader.parseEnv("URL=postgres://u:p=x@db:5432/app\n")
        #expect(values["URL"] == "postgres://u:p=x@db:5432/app")
    }
}
