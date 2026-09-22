import Foundation
import Observation

/// A progress update from the runtime, mirroring upstream's event vocabulary.
///
/// The runtime reports progress as running totals — tasks, items and bytes —
/// rather than per-layer rows. There is no per-blob breakdown to display, so
/// the UI shows the aggregate the runtime actually provides.
public enum PullProgressEvent: Sendable, Equatable {
    /// The phase, e.g. "Fetching image" then "Unpacking image".
    case description(String)
    case subDescription(String)
    /// What the items are: "blobs" while fetching, "entries" while unpacking.
    case itemsName(String)

    case addTasks(Int)
    case setTasks(Int)
    case addTotalTasks(Int)
    case setTotalTasks(Int)

    case addItems(Int)
    case setItems(Int)
    case addTotalItems(Int)
    case setTotalItems(Int)

    case addSize(Int64)
    case setSize(Int64)
    case addTotalSize(Int64)
    case setTotalSize(Int64)
}

/// The state of a pull, accumulated from the runtime's events.
public struct PullProgress: Sendable, Equatable {
    public var description: String = ""
    public var subDescription: String = ""
    public var itemsName: String = "items"

    public var tasks: Int = 0
    public var totalTasks: Int = 0
    public var items: Int = 0
    public var totalItems: Int = 0
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0

    public init() {}

    /// How far along, from the most meaningful measure available.
    ///
    /// Bytes are preferred — they move smoothly and match what the user is
    /// waiting for. Item counts jump in steps, and task counts are coarse. Nil
    /// when the runtime has not yet said how much there is to do, which is when
    /// a determinate bar would be a lie.
    public var fraction: Double? {
        if totalBytes > 0 {
            return min(1, Double(bytes) / Double(totalBytes))
        }
        if totalItems > 0 {
            return min(1, Double(items) / Double(totalItems))
        }
        return nil
    }

    /// A short line describing where the pull is, e.g. "3 of 7 blobs".
    public var itemsSummary: String? {
        guard totalItems > 0 else { return items > 0 ? "\(items) \(itemsName)" : nil }
        return "\(items) of \(totalItems) \(itemsName)"
    }

    /// e.g. "12.4 MB of 41.2 MB".
    ///
    /// `spellsOutZero` is off: the default renders the first moment of a pull
    /// as "Zero kB of 17.3 MB", which reads like a fault rather than a start.
    public var bytesSummary: String? {
        guard totalBytes > 0 else { return nil }
        let style = ByteCountFormatStyle(style: .file, spellsOutZero: false)
        return "\(bytes.formatted(style)) of \(totalBytes.formatted(style))"
    }

    public mutating func apply(_ event: PullProgressEvent) {
        switch event {
        case .description(let value):
            description = value
            // Each phase counts its own items and bytes, so a new phase must
            // not inherit the previous one's totals — otherwise "Unpacking"
            // starts at 100%.
            items = 0
            totalItems = 0
            bytes = 0
            totalBytes = 0
        case .subDescription(let value): subDescription = value
        case .itemsName(let value): itemsName = value

        case .addTasks(let value): tasks += value
        case .setTasks(let value): tasks = value
        case .addTotalTasks(let value): totalTasks += value
        case .setTotalTasks(let value): totalTasks = value

        case .addItems(let value): items += value
        case .setItems(let value): items = value
        case .addTotalItems(let value): totalItems += value
        case .setTotalItems(let value): totalItems = value

        case .addSize(let value): bytes += value
        case .setSize(let value): bytes = value
        case .addTotalSize(let value): totalBytes += value
        case .setTotalSize(let value): totalBytes = value
        }
    }

    public mutating func apply(_ events: [PullProgressEvent]) {
        for event in events { apply(event) }
    }
}

/// A pull the user started, and where it has got to.
@MainActor
@Observable
public final class PullJob: Identifiable, Sendable {
    public enum State: Sendable, Equatable {
        case running
        case succeeded
        case failed(DockyardError)
        case cancelled
    }

    public let id = UUID()
    /// What the user typed.
    public let requestedReference: String
    public let platform: String?
    public private(set) var progress = PullProgress()
    public private(set) var state: State = .running
    public let startedAt = Date()

    private var task: Task<Void, Never>?

    public init(requestedReference: String, platform: String?) {
        self.requestedReference = requestedReference
        self.platform = platform
    }

    public var isFinished: Bool { state != .running }

    func attach(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// Suspends until the pull has finished, however it finished.
    func waitUntilFinished() async {
        await task?.value
    }

    func update(_ progress: PullProgress) {
        self.progress = progress
    }

    func finish(_ state: State) {
        self.state = state
        task = nil
    }

    public func cancel() {
        task?.cancel()
    }
}
