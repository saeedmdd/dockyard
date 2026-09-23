import Foundation

/// Something worth telling the user about a compose file.
///
/// Identity is the content, not a UUID: the same problem reported twice is the
/// same diagnostic, which makes these comparable in tests and de-duplicable in
/// the UI.
public struct ComposeDiagnostic: Sendable, Hashable, Identifiable, Codable {
    public enum Severity: String, Sendable, Codable, CaseIterable {
        /// The file cannot be used until this is fixed.
        case error
        /// Dockyard will run it, but something is not as the author wrote it.
        case warning
        /// A key that has no equivalent here and was skipped. Distinct from a
        /// warning because there is nothing to fix — it is a statement of what
        /// this runtime cannot do.
        case ignored
    }

    public let severity: Severity
    /// Dotted path into the document, e.g. `services.web.healthcheck`.
    public let path: String
    public let message: String
    /// 1-based line in the source file, when the parser could attribute one.
    public let line: Int?

    public var id: String { "\(severity.rawValue)|\(path)|\(message)" }

    public init(severity: Severity, path: String, message: String, line: Int? = nil) {
        self.severity = severity
        self.path = path
        self.message = message
        self.line = line
    }

    public static func error(_ path: String, _ message: String, line: Int? = nil) -> Self {
        .init(severity: .error, path: path, message: message, line: line)
    }
    public static func warning(_ path: String, _ message: String, line: Int? = nil) -> Self {
        .init(severity: .warning, path: path, message: message, line: line)
    }
    public static func ignored(_ path: String, _ message: String, line: Int? = nil) -> Self {
        .init(severity: .ignored, path: path, message: message, line: line)
    }

    /// How it reads in a list: `services.web.healthcheck:12 — …`.
    public var display: String {
        line.map { "\(path):\($0) — \(message)" } ?? "\(path) — \(message)"
    }
}

extension [ComposeDiagnostic] {
    /// True when at least one diagnostic stops the file being used.
    public var blocks: Bool { contains { $0.severity == .error } }
    public var errors: [ComposeDiagnostic] { filter { $0.severity == .error } }
    public var warnings: [ComposeDiagnostic] { filter { $0.severity == .warning } }
    public var ignoredKeys: [ComposeDiagnostic] { filter { $0.severity == .ignored } }
}
