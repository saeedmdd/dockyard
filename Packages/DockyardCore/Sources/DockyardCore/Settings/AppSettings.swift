import Foundation
import Observation

/// The preferences the Settings window writes and the rest of the app reads.
///
/// Backed by `UserDefaults` directly rather than by SwiftUI's `@AppStorage`,
/// because these are read from `DockyardCore` — the poller, the backend, the
/// image list — where there is no view to attach a property wrapper to. Each
/// value is validated on the way in, so a hand-edited defaults plist cannot put
/// the app into a state its own UI would not allow.
@MainActor
@Observable
public final class AppSettings {
    /// Named so a `defaults read com.saeedmdd.Dockyard` is readable.
    enum Key {
        static let pollInterval = "pollIntervalSeconds"
        static let defaultPlatform = "defaultPlatform"
        static let showsInfrastructureImages = "showsInfrastructureImages"
        static let startsHidden = "startsHidden"
        static let cliPath = "cliPath"
        static let containersSort = "sort.containers"
        static let imagesSort = "sort.images"
        static let volumesSort = "sort.volumes"
        static let networksSort = "sort.networks"
    }

    public static let pollIntervalRange: ClosedRange<Double> = 1...10
    public static let defaultCLIPath = "/usr/local/bin/container"

    private let defaults: UserDefaults

    /// How often the lists refresh while something is on screen.
    public var pollIntervalSeconds: Double {
        didSet {
            let clamped = Self.clampInterval(pollIntervalSeconds)
            if clamped != pollIntervalSeconds {
                pollIntervalSeconds = clamped
                return
            }
            defaults.set(pollIntervalSeconds, forKey: Key.pollInterval)
            onPollIntervalChange?(pollInterval)
        }
    }

    public var pollInterval: Duration {
        .milliseconds(Int(pollIntervalSeconds * 1000))
    }

    /// Pre-filled in the Pull and Run sheets. Empty means "let the runtime
    /// choose", which is what upstream does when `--platform` is omitted.
    public var defaultPlatform: String {
        didSet { defaults.set(defaultPlatform, forKey: Key.defaultPlatform) }
    }

    /// Whether the Images list includes the builder and init images the runtime
    /// uses itself.
    public var showsInfrastructureImages: Bool {
        didSet {
            defaults.set(showsInfrastructureImages, forKey: Key.showsInfrastructureImages)
            onShowInfrastructureChange?(showsInfrastructureImages)
        }
    }

    /// Start into the menu bar without opening the window.
    public var startsHidden: Bool {
        didSet { defaults.set(startsHidden, forKey: Key.startsHidden) }
    }

    /// Where the `container` CLI lives, for installs that are not in the usual
    /// place. Blank restores the default rather than leaving the app pointed at
    /// nothing.
    public var cliPath: String {
        didSet {
            let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != cliPath {
                cliPath = trimmed
                return
            }
            defaults.set(cliPath, forKey: Key.cliPath)
        }
    }

    public var resolvedCLIPath: String {
        cliPath.isEmpty ? Self.defaultCLIPath : cliPath
    }

    /// Called when the interval changes, so the poller can be retimed without
    /// settings having to know what a poller is.
    public var onPollIntervalChange: (@MainActor (Duration) -> Void)?
    public var onShowInfrastructureChange: (@MainActor (Bool) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pollIntervalSeconds = Self.clampInterval(
            defaults.object(forKey: Key.pollInterval) as? Double ?? 2
        )
        defaultPlatform = defaults.string(forKey: Key.defaultPlatform) ?? ""
        showsInfrastructureImages = defaults.bool(forKey: Key.showsInfrastructureImages)
        startsHidden = defaults.bool(forKey: Key.startsHidden)
        cliPath = defaults.string(forKey: Key.cliPath) ?? ""
    }

    /// A poll interval outside the range the UI offers would either hammer the
    /// daemon or make the app look frozen.
    static func clampInterval(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 2 }
        return min(max(seconds, pollIntervalRange.lowerBound), pollIntervalRange.upperBound)
    }

    // MARK: - Table sort order

    /// Which list a saved sort belongs to.
    public enum SortedTable: String, Sendable, CaseIterable {
        case containers, images, volumes, networks

        var key: String {
            switch self {
            case .containers: Key.containersSort
            case .images: Key.imagesSort
            case .volumes: Key.volumesSort
            case .networks: Key.networksSort
            }
        }
    }

    /// A table's sort, as something storable.
    ///
    /// `KeyPathComparator` cannot be written to `UserDefaults`, so the column's
    /// title and the direction are stored and the view turns them back into a
    /// comparator. The title is what `Table` already uses to identify a column,
    /// which keeps the mapping in one place in the view that owns the columns.
    public struct SortSelection: Sendable, Hashable, Codable {
        public let column: String
        public let isAscending: Bool

        public init(column: String, isAscending: Bool) {
            self.column = column
            self.isAscending = isAscending
        }
    }

    public func sort(for table: SortedTable) -> SortSelection? {
        guard let data = defaults.data(forKey: table.key) else { return nil }
        return try? JSONDecoder().decode(SortSelection.self, from: data)
    }

    public func setSort(_ selection: SortSelection?, for table: SortedTable) {
        guard let selection, let data = try? JSONEncoder().encode(selection) else {
            defaults.removeObject(forKey: table.key)
            return
        }
        defaults.set(data, forKey: table.key)
    }
}
