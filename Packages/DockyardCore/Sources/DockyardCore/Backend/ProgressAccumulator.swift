import Foundation
import TerminalProgress

/// Turns the runtime's progress events into `PullProgress` snapshots.
///
/// The runtime hands over a `ProgressUpdateHandler` that it calls with batches
/// of events from whatever thread it likes, so state is kept behind a lock. The
/// translation from upstream's event type happens here, which keeps
/// `TerminalProgress` out of the models and the UI.
final class ProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = PullProgress()
    private let onChange: @Sendable (PullProgress) -> Void

    init(onChange: @escaping @Sendable (PullProgress) -> Void) {
        self.onChange = onChange
    }

    /// Names the phase locally, because the runtime never sends one.
    func setPhase(description: String, itemsName: String) {
        let snapshot = lock.withLock { () -> PullProgress in
            progress.apply([.description(description), .itemsName(itemsName)])
            return progress
        }
        onChange(snapshot)
    }

    var handler: ProgressUpdateHandler {
        { [weak self] events in
            guard let self else { return }
            let snapshot = lock.withLock { () -> PullProgress in
                progress.apply(events.compactMap(PullProgressEvent.init(upstream:)))
                return progress
            }
            onChange(snapshot)
        }
    }
}

extension PullProgressEvent {
    /// `.custom` carries a free-form string the terminal renderer uses for its
    /// own purposes; there is nothing for a GUI to show, so it is dropped.
    init?(upstream event: ProgressUpdateEvent) {
        switch event {
        case .setDescription(let value): self = .description(value)
        case .setSubDescription(let value): self = .subDescription(value)
        case .setItemsName(let value): self = .itemsName(value)
        case .addTasks(let value): self = .addTasks(value)
        case .setTasks(let value): self = .setTasks(value)
        case .addTotalTasks(let value): self = .addTotalTasks(value)
        case .setTotalTasks(let value): self = .setTotalTasks(value)
        case .addItems(let value): self = .addItems(value)
        case .setItems(let value): self = .setItems(value)
        case .addTotalItems(let value): self = .addTotalItems(value)
        case .setTotalItems(let value): self = .setTotalItems(value)
        case .addSize(let value): self = .addSize(value)
        case .setSize(let value): self = .setSize(value)
        case .addTotalSize(let value): self = .addTotalSize(value)
        case .setTotalSize(let value): self = .setTotalSize(value)
        case .custom: return nil
        }
    }
}
