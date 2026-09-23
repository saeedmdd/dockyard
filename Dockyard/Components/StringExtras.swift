import Foundation

extension String {
    /// Nil instead of an empty string, so `if let` reads as "is there anything
    /// to show" at the several places that build a detail line out of optional
    /// parts.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
