import Foundation

/// Variable substitution in a compose file.
///
/// Not optional in practice — nearly every real file has at least a
/// `${TAG:-latest}` in it, and a parser that cannot do this rejects files that
/// work everywhere else.
///
/// Follows the compose specification: `$VAR`, `${VAR}`, `${VAR:-default}`
/// (default when unset *or empty*), `${VAR-default}` (default only when unset),
/// `${VAR:?message}` and `${VAR?message}` (an error naming the variable), and
/// `$$` for a literal `$`.
public enum ComposeInterpolation {

    public struct Failure: Sendable, Equatable {
        public let variable: String
        public let message: String
    }

    /// Substitutes into `text`, collecting any `:?` failures rather than
    /// throwing on the first — a file missing three variables should say so
    /// once, not three times in a row.
    public static func expand(
        _ text: String,
        values: [String: String],
        failures: inout [Failure]
    ) -> String {
        var out = ""
        var rest = Substring(text)

        while let dollar = rest.firstIndex(of: "$") {
            out += rest[rest.startIndex..<dollar]
            rest = rest[rest.index(after: dollar)...]

            guard let first = rest.first else {
                // A trailing `$` is literal; compose does not treat it as an error.
                out += "$"
                break
            }

            if first == "$" {
                out += "$"
                rest = rest.dropFirst()
            } else if first == "{" {
                guard let close = matchingBrace(in: rest) else {
                    // Unterminated `${` — emit it literally rather than
                    // swallowing the rest of the value.
                    out += "$"
                    continue
                }
                let body = rest[rest.index(after: rest.startIndex)..<close]
                out += resolve(String(body), values: values, failures: &failures)
                rest = rest[rest.index(after: close)...]
            } else if first.isLetter || first == "_" {
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                out += values[String(name)] ?? ""
                rest = rest.dropFirst(name.count)
            } else {
                // `$` followed by punctuation is literal, e.g. a bcrypt hash.
                out += "$"
            }
        }
        out += rest
        return out
    }

    /// The values a compose file interpolates from: the process environment,
    /// overlaid on a `.env` file. Process wins, per the specification.
    public static func values(processEnvironment: [String: String], dotEnv: [String: String]) -> [String: String] {
        dotEnv.merging(processEnvironment) { _, process in process }
    }

    private static func matchingBrace(in text: Substring) -> Substring.Index? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `VAR`, `VAR:-default`, `VAR-default`, `VAR:?message`, `VAR?message`.
    private static func resolve(
        _ body: String,
        values: [String: String],
        failures: inout [Failure]
    ) -> String {
        for (marker, treatEmptyAsUnset) in [(":-", true), ("-", false)] {
            if let range = body.range(of: marker), !range.lowerBound.isEqual(to: body.startIndex) {
                let name = String(body[body.startIndex..<range.lowerBound])
                let fallback = String(body[range.upperBound...])
                let value = values[name]
                let missing = treatEmptyAsUnset ? (value ?? "").isEmpty : value == nil
                return missing ? fallback : (value ?? "")
            }
        }
        for (marker, treatEmptyAsUnset) in [(":?", true), ("?", false)] {
            if let range = body.range(of: marker), !range.lowerBound.isEqual(to: body.startIndex) {
                let name = String(body[body.startIndex..<range.lowerBound])
                let note = String(body[range.upperBound...])
                let value = values[name]
                let missing = treatEmptyAsUnset ? (value ?? "").isEmpty : value == nil
                if missing {
                    failures.append(
                        Failure(
                            variable: name,
                            message: note.isEmpty ? "is required but not set" : note
                        )
                    )
                    return ""
                }
                return value ?? ""
            }
        }
        return values[body] ?? ""
    }
}

extension String.Index {
    fileprivate func isEqual(to other: String.Index) -> Bool { self == other }
}
