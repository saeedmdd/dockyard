import Foundation

/// The runtime's own rule for what a container, volume or network may be called.
///
/// `apple/container` 1.0.0 exposed this as `Utility.validEntityName`. 1.4.1
/// removed it and moved validation into the resource types, which reject a bad
/// name only once a configuration is built — and for containers not at all. The
/// rule itself did not change, so it lives here now: the app can reject a name
/// in the sheet, where the user can still fix it, rather than after a round
/// trip to the daemon.
enum EntityName {
    /// A letter or digit, then letters, digits, underscores, dots or hyphens.
    /// At least two characters, which is upstream's rule and not an oversight
    /// of ours: the `+` in the pattern requires a second character.
    ///
    /// Built per call rather than held in a `static let`, because `Regex` is
    /// not `Sendable` and a shared one is a data race under strict concurrency.
    /// Matching one short name is not worth a lock to avoid.
    static func validate(_ name: String) throws {
        let pattern = /^[a-zA-Z0-9][a-zA-Z0-9_.-]+$/
        guard try pattern.firstMatch(in: name) != nil else {
            throw DockyardError.upstream(
                code: "invalidArgument",
                message: "“\(name)” is not a usable name. Start with a letter or number, "
                    + "then use letters, numbers, dots, dashes or underscores."
            )
        }
    }

    static func isValid(_ name: String) -> Bool {
        (try? validate(name)) != nil
    }
}
